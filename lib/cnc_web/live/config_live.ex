defmodule CNCWeb.ConfigLive do
  @moduledoc """
  The machine's configuration (`/configuration`, `CNC.Configuration`), in
  tabs: Profiles, Build, Wiring (the controller in use), File (its config
  file, the check, overrides) and History. A status strip on every tab says
  which controller, which profile, and whether its file is in step.

  Edits anywhere are staged into one changeset (`CNC.Configuration.Changes`,
  shared by every screen); a bar shows what's pending, and Review & apply
  shows the whole diff, grouped by part, before applying it together ("Apply
  now" stages and reviews just those edits). Actions that replace everything
  (switching profile, an override, a restore) are approved on their own
  diff.
  """
  use CNCWeb, :live_view

  on_mount CNCWeb.Pin

  import CNCWeb.YamlView, only: [yaml_view: 1]

  alias CNC.{Controllers, Machine}
  alias CNC.Configuration
  alias CNC.Configuration.{Build, Changes, FluidNC, History, Profiles, Values, Wiring}

  @tabs [
    profiles: "Profiles",
    build: "Build",
    wiring: "Wiring",
    file: "File",
    history: "History"
  ]

  @axis_fields [
    {"steps_per_mm", "Steps per mm"},
    {"max_rate_mm_per_min", "Max rate (mm/min)"},
    {"acceleration_mm_per_sec2", "Acceleration (mm/s²)"},
    {"max_travel_mm", "Max travel (mm)"}
  ]

  @impl true
  def mount(_params, session, socket) do
    cnc = CNCWeb.Instance.from_session(session)

    if connected?(socket) do
      Controllers.subscribe(cnc.controllers_topic)
      Changes.subscribe(cnc.db)
    end

    {:ok,
     socket
     |> assign(page_title: "Configuration", cnc: cnc, controller: nil, tab: :profiles)
     |> assign(machine: Machine.status(cnc.machine))
     |> assign(profiles: [], check: nil, running: %{}, paths: [], drift: [])
     |> assign(wiring: %{checked: 0, differences: []}, history: [])
     |> assign(build_history: [], wiring_history: [], current: %{})
     |> assign(staged: Changes.list(cnc.db), stale: [], field_errors: %{})
     |> assign(editing: nil, other: %{}, viewing: nil, text: nil, renaming: nil)
     |> assign(showing: MapSet.new(), expanded: MapSet.new(), paste: "")
     |> assign(new: %{"name" => "", "from" => ""}, dialog: nil, reviewing: nil)
     |> assign(working: nil, error: nil)
     |> allow_upload(:config_file, accept: :any, max_entries: 1, max_file_size: 256_000)
     |> refresh_active()
     |> load()}
  end

  @impl true
  def handle_params(_params, _uri, socket),
    do: {:noreply, assign(socket, tab: socket.assigns.live_action || :profiles)}

  @impl true
  def handle_info({:machine, machine}, socket) do
    was_ready? = ready?(socket.assigns)
    socket = assign(socket, machine: machine)

    # Came back (connected, or after a restart): read everything again.
    if ready?(socket.assigns) and not was_ready?,
      do: {:noreply, socket |> assign(working: nil) |> load()},
      else: {:noreply, socket}
  end

  # Another controller connected (or none): its wiring and file now.
  def handle_info({:controllers, _}, socket) do
    before = socket.assigns.controller
    socket = refresh_active(socket)

    if socket.assigns.controller != before,
      do: {:noreply, socket |> assign(check: nil, working: nil) |> load()},
      else: {:noreply, socket}
  end

  def handle_info({:configuration_changes, staged}, socket),
    do: {:noreply, socket |> assign(staged: staged) |> mark_stale()}

  ## Editing: staging into the changeset

  @impl true
  def handle_event("edit", %{"part" => part} = params, socket),
    do: {:noreply, assign(socket, editing: {part, params["target"]}, field_errors: %{})}

  def handle_event("done_editing", _, socket),
    do: {:noreply, assign(socket, editing: nil, field_errors: %{})}

  # A values form (any part): what differs from its part's values is staged;
  # "Apply now" also opens the review for just those.
  def handle_event("stage", %{"part" => part, "set" => values} = params, socket) do
    part = String.to_existing_atom(part)
    target = blank_to_nil(params["target"])
    base = part_values(socket.assigns, part, target)

    {changes, errors} =
      Enum.reduce(values, {[], %{}}, fn {path, value}, {ok, bad} ->
        value = String.trim(value)

        cond do
          value == "" or
              same_value?(staged_to(socket.assigns, part, target, path) || base[path], value) ->
            {ok, bad}

          Build.layer(path) != part ->
            {ok, Map.put(bad, path, error_text(:wrong_part))}

          true ->
            case Profiles.check_value(value, base[path]) do
              {:ok, v} ->
                {[%{part: part, target: target, path: path, from: base[path], to: v} | ok], bad}

              {:error, reason} ->
                {ok, Map.put(bad, path, error_text(reason))}
            end
        end
      end)

    :ok = Changes.stage(socket.assigns.cnc.db, Enum.reverse(changes))
    socket = assign(socket, staged: Changes.list(socket.assigns.cnc.db), field_errors: errors)

    socket =
      if errors == %{}, do: assign(socket, editing: nil), else: socket

    if params["intent"] == "now" and changes != [],
      do: {:noreply, open_review(socket, Enum.map(changes, &Changes.key/1))},
      else: {:noreply, mark_stale(socket)}
  end

  # "Any other value": a path and a value, staged in the part it belongs to.
  def handle_event("other_change", %{"other" => other}, socket),
    do: {:noreply, assign(socket, other: other)}

  def handle_event(
        "stage_other",
        %{"other" => %{"path" => path, "value" => value}} = params,
        socket
      ) do
    %{controller: c} = socket.assigns
    path = Profiles.clean(path)

    target =
      case Build.layer(path) do
        :profile -> params["profile"]
        :wiring -> c && c.id
        _ -> nil
      end

    case Build.layer(path) do
      :label ->
        {:noreply, assign(socket, error: error_text(:not_editable))}

      part ->
        handle_event(
          "stage",
          %{
            "part" => to_string(part),
            "target" => target,
            "set" => %{path => value},
            "intent" => params["intent"]
          },
          assign(socket, other: %{}, error: nil)
        )
    end
  end

  def handle_event("drop_change", %{"key" => key}, socket) do
    :ok = Changes.drop(socket.assigns.cnc.db, [key])
    staged = Changes.list(socket.assigns.cnc.db)

    reviewing =
      if is_list(socket.assigns.reviewing),
        do: socket.assigns.reviewing -- [key],
        else: socket.assigns.reviewing

    reviewing = if staged == [] or reviewing == [], do: nil, else: reviewing
    {:noreply, socket |> assign(staged: staged, reviewing: reviewing) |> mark_stale()}
  end

  def handle_event("discard", _, socket) do
    :ok = Changes.clear(socket.assigns.cnc.db)
    {:noreply, assign(socket, staged: [], stale: [], reviewing: nil)}
  end

  def handle_event("review", _, socket), do: {:noreply, open_review(socket, :all)}
  def handle_event("close_review", _, socket), do: {:noreply, assign(socket, reviewing: nil)}

  def handle_event("apply", _, socket) do
    %{cnc: cnc, controller: c} = socket.assigns
    changes = reviewed(socket.assigns)

    case Configuration.apply(cnc.machine, cnc.db, c, changes) do
      {:ok, %{errors: errors, restart?: restart?}} ->
        socket =
          socket
          |> assign(reviewing: nil, staged: Changes.list(cnc.db))
          |> assign(error: if(errors == %{}, do: nil, else: apply_errors(errors)))

        if restart?,
          do: {:noreply, assign(socket, working: "Wiring changed: the controller restarts…")},
          else: {:noreply, socket |> load() |> mark_stale()}
    end
  end

  ## Profiles

  def handle_event("switch", %{"profile" => pid}, socket) do
    %{profiles: profiles, check: check, staged: staged} = socket.assigns

    case Enum.find(profiles, &(&1.id == pid)) do
      nil ->
        {:noreply, assign(socket, error: error_text(:not_found))}

      target ->
        again? = check && check.profile.id == pid

        staged_note =
          if staged == [],
            do: "",
            else: " Your #{count_label(length(staged))} staged stay staged."

        ask(socket,
          title:
            if(again?,
              do: "Write #{target.name} to the controller",
              else: "Switch to #{target.name}"
            ),
          note:
            "The controller's file becomes its wiring, the build and #{target.name}; it restarts and comes back locked." <>
              staged_note,
          approve: if(again?, do: "Write and restart", else: "Switch and restart"),
          diffs:
            cond do
              again? -> check_diffs(check) |> Enum.map(&%{&1 | from: &1.to, to: &1.from})
              check -> Profiles.diff(check.profile, target)
              true -> []
            end,
          from_label: if(again?, do: "file", else: check && check.profile.name),
          to_label: target.name,
          action: {:switch, pid}
        )
    end
  end

  def handle_event("new_change", %{"new" => new}, socket),
    do: {:noreply, assign(socket, new: new)}

  def handle_event("create", %{"new" => %{"name" => name} = new}, socket) do
    %{cnc: cnc, controller: c} = socket.assigns

    from =
      case new["from"] do
        "board" -> :board
        empty when empty in [nil, ""] -> default_from(socket.assigns)
        pid -> pid
      end

    case Profiles.create(cnc.db, name, c.board, from) do
      {:ok, p} ->
        {:noreply,
         socket
         |> assign(new: %{"name" => "", "from" => ""}, error: nil)
         |> put_flash(:info, "Made #{p.name}. Switch to it to use it.")
         |> load()}

      {:error, reason} ->
        {:noreply, assign(socket, new: new, error: error_text(reason))}
    end
  end

  def handle_event("rename", %{"profile" => pid}, socket),
    do: {:noreply, assign(socket, renaming: pid)}

  def handle_event("cancel_rename", _, socket), do: {:noreply, assign(socket, renaming: nil)}

  def handle_event("save_name", %{"profile" => pid, "name" => name}, socket) do
    case Profiles.rename(socket.assigns.cnc.db, pid, name) do
      :ok -> {:noreply, socket |> assign(renaming: nil, error: nil) |> load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("delete_profile", %{"profile" => pid}, socket) do
    case Profiles.delete(socket.assigns.cnc.db, pid) do
      :ok -> {:noreply, socket |> assign(error: nil) |> load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  # View, diff and history panels on a profile (or the build/wiring).
  def handle_event("toggle", %{"key" => key}, socket) do
    showing = socket.assigns.showing

    showing =
      if MapSet.member?(showing, key),
        do: MapSet.delete(showing, key),
        else: MapSet.put(showing, key)

    {:noreply, assign(socket, showing: showing)}
  end

  def handle_event("toggle_rev", %{"key" => key}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, assign(socket, expanded: expanded)}
  end

  ## Restores (each its own version, shown as a diff first)

  def handle_event("restore_profile", %{"profile" => pid, "i" => i}, socket) do
    %{cnc: cnc, profiles: profiles, check: check} = socket.assigns
    i = String.to_integer(i)
    profile = Enum.find(profiles, &(&1.id == pid))
    rev = profile && Enum.at(profile.history, i)
    selected? = check && check.profile.id == pid

    if rev do
      ask(socket,
        title: "Restore #{profile.name} to v#{rev.version}",
        note:
          if(selected?,
            do: "A new version of #{profile.name}, written to the controller, which restarts.",
            else:
              "A new version of #{profile.name}; the controller gets it when you switch to it."
          ),
        approve: if(selected?, do: "Restore and restart", else: "Restore"),
        diffs: Profiles.restore_diff(cnc.db, pid, i),
        from_label: "now",
        to_label: "v#{rev.version}",
        action: {:restore_profile, pid, i}
      )
    else
      {:noreply, assign(socket, error: error_text(:not_found))}
    end
  end

  def handle_event("restore_part", %{"part" => part, "i" => i}, socket)
      when part in ["build", "wiring"] do
    %{cnc: cnc, controller: c} = socket.assigns
    i = String.to_integer(i)

    {history, now} =
      if part == "build",
        do: {socket.assigns.build_history, Build.values(cnc.db)},
        else: {socket.assigns.wiring_history, Wiring.values(cnc.db, c.id)}

    case Enum.at(history, i) do
      %{values: values, version: v} ->
        ask(socket,
          title: "Restore the #{part} to v#{v}",
          note: "A new version of the #{part}, written to the controller, which restarts.",
          approve: "Restore and restart",
          diffs: Values.diff_maps(now, values),
          from_label: "now",
          to_label: "v#{v}",
          action: {:restore_part, String.to_existing_atom(part), i}
        )

      nil ->
        {:noreply, assign(socket, error: error_text(:not_found))}
    end
  end

  def handle_event("restore_file", %{"i" => i}, socket) do
    %{history: history, check: check} = socket.assigns

    case Enum.at(history, String.to_integer(i)) do
      %{text: text, version: v} = rev when is_binary(text) ->
        ask(socket,
          title: "Restore the controller's file to v#{v}",
          note:
            "#{rev.file} gets v#{v}'s file back (a new version); the controller restarts with it.",
          approve: "Restore and restart",
          diffs: Values.diff_texts(check && check.text, text),
          from_label: "now",
          to_label: "v#{v}",
          action: {:restore_file, String.to_integer(i)}
        )

      _ ->
        {:noreply, assign(socket, error: error_text(:no_file))}
    end
  end

  ## File: the check, running values, the file itself, overrides

  def handle_event("take_file", _, socket) do
    %{cnc: cnc, controller: c, check: check} = socket.assigns

    case Configuration.drift(cnc.machine, cnc.db, c) do
      {:ok, drift} ->
        ask(socket,
          title: "Keep the controller's values",
          note:
            "What the controller runs becomes the wiring, the build and #{check.profile.name}; then it's written and the controller restarts.",
          approve: "Keep, write and restart",
          diffs: for(d <- drift, do: %{path: d.path, from: d.profile, to: d.controller}),
          from_label: "configuration",
          to_label: "running",
          action: :take_file
        )

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("keep_drift", _, socket) do
    ask(socket,
      title: "Keep the running values",
      note: "They go into their parts and the config file. Nothing restarts.",
      approve: "Keep",
      diffs:
        for(d <- socket.assigns.drift, do: %{path: d.path, from: d.profile, to: d.controller}),
      from_label: "configuration",
      to_label: "running",
      action: :keep_drift
    )
  end

  def handle_event("put_back", _, socket) do
    ask(socket,
      title: "Put the configuration's values back",
      note: "Set on the controller straight away. Nothing restarts.",
      approve: "Put back",
      diffs:
        for(d <- socket.assigns.drift, do: %{path: d.path, from: d.controller, to: d.profile}),
      from_label: "running",
      to_label: "configuration",
      action: :put_back
    )
  end

  def handle_event("view", _, socket) do
    if socket.assigns.viewing,
      do: {:noreply, assign(socket, viewing: nil, text: nil)},
      else:
        {:noreply,
         assign(socket,
           viewing: active_file(socket.assigns),
           text: socket.assigns.check && socket.assigns.check.text
         )}
  end

  def handle_event("validate_upload", params, socket),
    do: {:noreply, assign(socket, paste: Map.get(params, "paste", socket.assigns.paste))}

  def handle_event("review_override", params, socket) do
    uploaded =
      consume_uploaded_entries(socket, :config_file, fn %{path: path}, entry ->
        {:ok, {entry.client_name, File.read!(path)}}
      end)

    paste = String.trim(Map.get(params, "paste", ""))

    source =
      case uploaded do
        [{name, text}] ->
          if Regex.match?(~r/\.ya?ml\z/i, name),
            do: {:ok, text, "Uploaded #{name} (an override)"},
            else: {:error, :not_yaml}

        [] when paste != "" ->
          {:ok, paste <> "\n", "Pasted a config (an override)"}

        [] ->
          {:error, :nothing_to_use}
      end

    with {:ok, text, reason} <- source,
         true <- Values.parse(text) != [] || {:error, :not_a_config} do
      ask(socket,
        title: "Use your own config",
        note:
          "It replaces #{Configuration.file()} (wiring included) and the controller restarts with it. Recorded as: #{reason}.",
        approve: "Write and restart",
        diffs: Values.diff_texts(socket.assigns.check && socket.assigns.check.text, text),
        from_label: Configuration.file(),
        to_label: "yours",
        action: {:override, text, reason}
      )
    else
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  ## The approval dialog

  def handle_event("cancel_dialog", _, socket), do: {:noreply, assign(socket, dialog: nil)}
  def handle_event("approve", _, %{assigns: %{dialog: nil}} = socket), do: {:noreply, socket}

  def handle_event("approve", _, socket) do
    action = socket.assigns.dialog.action
    run(assign(socket, dialog: nil), action)
  end

  defp run(socket, action) do
    %{cnc: cnc, controller: c, check: check} = socket.assigns
    m = cnc.machine
    selected? = fn pid -> check && check.profile.id == pid end

    {result, restarts?} =
      case action do
        {:switch, pid} ->
          {Configuration.switch(m, cnc.db, c, pid), true}

        {:restore_profile, pid, i} ->
          {Configuration.restore_profile(m, cnc.db, c, pid, i), selected?.(pid)}

        {:restore_part, part, i} ->
          {Configuration.restore_part(m, cnc.db, c, part, i), true}

        {:restore_file, i} ->
          {restore_file(socket, i), true}

        {:override, text, reason} ->
          {Configuration.replace_file(m, cnc.db, c, text, reason), true}

        :take_file ->
          {Configuration.take_file(m, cnc.db, c), true}

        :keep_drift ->
          {Configuration.keep_drift(m, cnc.db, c), false}

        :put_back ->
          {Configuration.put_back(m, cnc.db, c), false}
      end

    case result do
      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}

      _ when restarts? ->
        {:noreply,
         assign(socket, working: "Writing it: the controller restarts…", error: nil, paste: "")}

      _ ->
        {:noreply, socket |> assign(error: nil, paste: "") |> load()}
    end
  end

  defp restore_file(socket, i) do
    %{cnc: cnc, controller: c, history: history} = socket.assigns

    with %{} = rev <- Enum.at(history, i) || {:error, :not_found},
         {:ok, file} <- History.restore(cnc.machine, cnc.db, c.id, rev) do
      if file == Configuration.file(), do: FluidNC.activate(cnc.machine, file), else: :ok
    end
  end

  defp ask(socket, opts), do: {:noreply, assign(socket, dialog: Map.new(opts))}

  defp open_review(socket, keys) do
    socket = mark_stale(socket)
    if socket.assigns.staged == [], do: socket, else: assign(socket, reviewing: keys)
  end

  defp reviewed(%{reviewing: :all, staged: staged}), do: staged

  defp reviewed(%{reviewing: keys, staged: staged}) when is_list(keys),
    do: Enum.filter(staged, &(Changes.key(&1) in keys))

  defp reviewed(_), do: []

  defp mark_stale(socket) do
    %{cnc: cnc, controller: c, staged: staged} = socket.assigns
    assign(socket, stale: if(c, do: Configuration.stale(cnc.db, c, staged), else: []))
  end

  defp apply_errors(errors) do
    "Some changes weren't applied and stay staged: " <>
      Enum.map_join(errors, "; ", fn {key, reason} ->
        [_, _, path] = String.split(key, ":", parts: 3)
        "#{path}: #{error_text(reason)}"
      end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:configuration} machine={@shell_machine}>
      <div class={["ui-page", "cnc-config", @staged != [] && "has-pending"]}>
        <UI.page_header title="Configuration">
          <:description>
            How the machine is built, wired and run, and the config file on the controller in
            use. Edits are staged, then reviewed and applied together.
          </:description>
        </UI.page_header>

        <div>
          <p :if={@error} id="config-error" class="cnc-set-error">{@error}</p>

          <%= cond do %>
            <% @controller == nil -> %>
              <section class="cnc-set-group" id="config-not-connected">
                <p class="cnc-note">
                  No controller is in use. Connect one to see and change the configuration: the
                  machine's build and profiles are kept here and written to it.
                </p>
                <div class="cnc-row">
                  <UI.button variant="primary" navigate={~p"/controllers"}>
                    Go to Controllers
                  </UI.button>
                </div>
              </section>
            <% @working -> %>
              <p class="cnc-note" id="config-working">{@working}</p>
            <% not ready?(assigns) or @check == nil -> %>
              <p class="cnc-note" id="config-waiting">{waiting_text(@machine.state)}</p>
            <% true -> %>
              <.status_strip check={@check} controller={@controller} staged={@staged} />

              <UI.tabs
                label="Configuration"
                current={@tab}
                items={
                  for {tab, label} <- tabs(), do: {tab, label, tab_path(tab), staged_in(@staged, tab)}
                }
              />

              {tab_content(assigns)}
          <% end %>
        </div>

        <div :if={@staged != [] and @controller} class="cnc-pending" id="pending-bar" role="status">
          <span class="cnc-pending-what">
            <strong>{count_label(length(@staged))} staged</strong>
            <span class="cnc-dim">{staged_summary(assigns)}</span>
            <span :if={@stale != []} class="cnc-warn">
              · {length(@stale)} changed elsewhere since
            </span>
          </span>
          <span class="cnc-row">
            <UI.button
              variant="quiet"
              id="discard-staged"
              phx-click="discard"
              data-confirm={"Discard the #{count_label(length(@staged))} staged?"}
            >
              Discard
            </UI.button>
            <UI.button
              variant="primary"
              id="review-staged"
              phx-click="review"
            >
              Review &amp; apply
            </UI.button>
          </span>
        </div>

        <%= if @reviewing do %>
          {review(assigns)}
        <% end %>
        <.dialog :if={@dialog} dialog={@dialog} machine={@machine} />
      </div>
    </Layouts.app>
    """
  end

  defp tab_content(%{tab: :profiles} = assigns) do
    ~H"""
    <section class="cnc-set-group" id="tab-panel-profiles" aria-label="Profiles">
      <p class="cnc-sub">
        How the machine is run: rates, acceleration, homing speeds. The selected one is on the
        controller; switch to try another. They carry over to any controller.
      </p>
      <ul class="cnc-ctls" id="profiles">
        <li
          :for={p <- ordered_profiles(@profiles, @check)}
          id={"profile-#{p.id}"}
          class={["cnc-ctl-card", selected?(@check, p) && "is-active"]}
        >
          <div class="cnc-ctl-card-head">
            <h3 :if={@renaming != p.id} class="cnc-ctl-name">{p.name}</h3>
            <.rename_form :if={@renaming == p.id} profile={p} />
            <span :if={selected?(@check, p)} class="cnc-ctl-tag">Selected</span>
          </div>

          <form
            :if={@editing == {"profile", p.id}}
            id={"edit-profile-#{p.id}"}
            class="cnc-axes-form"
            phx-submit="stage"
          >
            <input type="hidden" name="part" value="profile" />
            <input type="hidden" name="target" value={p.id} />
            <.axes_table
              values={
                Map.merge(
                  Configuration.expected(@cnc.db, @controller, p),
                  staged_map(@staged, :profile, p.id)
                )
              }
              staged={staged_map(@staged, :profile, p.id)}
              editable
              layer={:profile}
              id_prefix={"set-#{p.id}"}
              errors={@field_errors}
            />
            <.values_list
              id={"values-#{p.id}"}
              values={p.values}
              staged={staged_map(@staged, :profile, p.id)}
              skip={axis_paths()}
              editable
              errors={@field_errors}
            />
            <.stage_buttons />
          </form>

          <div :if={@editing != {"profile", p.id}}>
            <.axes_table
              values={
                Map.merge(
                  Configuration.expected(@cnc.db, @controller, p),
                  staged_map(@staged, :profile, p.id)
                )
              }
              staged={staged_map(@staged, :profile, p.id)}
              id_prefix={"view-#{p.id}"}
            />
          </div>

          <div :if={@renaming != p.id and @editing != {"profile", p.id}} class="cnc-row">
            <UI.button
              :if={not selected?(@check, p)}
              variant="primary"
              phx-click="switch"
              phx-value-profile={p.id}
              disabled={@machine.moving?}
            >
              Switch to this
            </UI.button>
            <UI.button
              id={"edit-#{p.id}"}
              phx-click="edit"
              phx-value-part="profile"
              phx-value-target={p.id}
            >
              Edit
            </UI.button>
            <UI.button type="button" phx-click="toggle" phx-value-key={"file-#{p.id}"}>
              {if MapSet.member?(@showing, "file-#{p.id}"), do: "Hide file", else: "View file"}
            </UI.button>
            <UI.button
              :if={not selected?(@check, p)}
              phx-click="toggle"
              phx-value-key={"diff-#{p.id}"}
            >
              {if MapSet.member?(@showing, "diff-#{p.id}"),
                do: "Hide diff",
                else: "Diff with selected"}
            </UI.button>
            <UI.button type="button" phx-click="toggle" phx-value-key={"history-#{p.id}"}>
              {if MapSet.member?(@showing, "history-#{p.id}"), do: "Hide history", else: "History"}
            </UI.button>
            <UI.button
              variant="quiet"
              phx-click="rename"
              phx-value-profile={p.id}
            >
              Rename
            </UI.button>
            <UI.button
              :if={not selected?(@check, p)}
              variant="quiet"
              phx-click="delete_profile"
              phx-value-profile={p.id}
              data-confirm={"Delete the profile #{p.name}?"}
            >
              Delete
            </UI.button>
          </div>

          <div :if={MapSet.member?(@showing, "diff-#{p.id}")} id={"diff-#{p.id}"} class="cnc-diff">
            <%= case Profiles.diff(@check.profile, p) do %>
              <% [] -> %>
                <p class="cnc-sub">Same values as {@check.profile.name}.</p>
              <% diffs -> %>
                <p class="cnc-sub">
                  {count_label(length(diffs))} {if length(diffs) == 1, do: "differs", else: "differ"} ({@check.profile.name} → {p.name}):
                </p>
                <.diff_list diffs={diffs} />
            <% end %>
          </div>
          <.yaml_view
            :if={MapSet.member?(@showing, "file-#{p.id}")}
            id={"yaml-#{p.id}"}
            text={Configuration.render(@cnc.db, @controller, p)}
          />
          <.revisions
            :if={MapSet.member?(@showing, "history-#{p.id}")}
            id={"history-#{p.id}"}
            entries={p.history}
            prefix={"p-#{p.id}"}
            expanded={@expanded}
            restore="restore_profile"
            values={%{"profile" => p.id}}
          />
        </li>
      </ul>

      <form id="new-profile-form" class="cnc-ctl-form" phx-change="new_change" phx-submit="create">
        <h3 class="cnc-sub">New profile</h3>
        <div class="cnc-other-row">
          <label class="cnc-ctl-field">
            <span>Name</span>
            <input name="new[name]" value={@new["name"]} placeholder="Fast accel" autocomplete="off" />
          </label>
          <label class="cnc-ctl-field">
            <span>Starting from</span>
            <select name="new[from]">
              <option
                :for={p <- @profiles}
                value={p.id}
                selected={@new["from"] == p.id or (@new["from"] == "" and selected?(@check, p))}
              >
                A copy of {p.name}
              </option>
              <option value="board" selected={@new["from"] == "board"}>The board's default</option>
            </select>
          </label>
        </div>
        <div class="cnc-row">
          <UI.button type="submit">Make profile</UI.button>
        </div>
      </form>
    </section>
    """
  end

  defp tab_content(%{tab: :build} = assigns) do
    ~H"""
    <section class="cnc-set-group" id="tab-panel-build" aria-label="Build">
      <p class="cnc-sub">
        How the machine is put together: steps per mm, travel, homing direction and position,
        limits. The same for every profile, and carried over to any controller.
      </p>
      <.part_editor
        part="build"
        values={Build.values(@cnc.db)}
        staged={staged_map(@staged, :build, nil)}
        editing={@editing == {"build", nil}}
        errors={@field_errors}
      />
      <div class="cnc-row">
        <UI.button
          id="build-history"
          phx-click="toggle"
          phx-value-key="history-build"
        >
          {if MapSet.member?(@showing, "history-build"), do: "Hide history", else: "History"}
        </UI.button>
      </div>
      <.revisions
        :if={MapSet.member?(@showing, "history-build")}
        id="history-build"
        entries={@build_history}
        prefix="b"
        expanded={@expanded}
        restore="restore_part"
        values={%{"part" => "build"}}
      />
    </section>
    """
  end

  defp tab_content(%{tab: :wiring} = assigns) do
    ~H"""
    <section class="cnc-set-group" id="tab-panel-wiring" aria-label="Wiring">
      <p class="cnc-sub">
        How {@controller.name} is wired to the machine: pins (with direction inversion), the
        stepping engine and buses. Changes take effect after a restart.
      </p>
      <p :if={@wiring.checked > 0 and @wiring.differences == []} class="cnc-sub" id="wiring-ok">
        Matches the {CNC.Boards.label(@controller.board)} pin map ({@wiring.checked} values).
      </p>
      <div :if={@wiring.differences != []} id="wiring-differences" class="cnc-warn-block">
        <p class="cnc-warn">
          Differs from the {CNC.Boards.label(@controller.board)} pin map: check the board is
          right, or that the wiring changed on purpose.
        </p>
        <.diff_list diffs={
          for w <- @wiring.differences, do: %{path: w.path, from: w.board, to: w.controller}
        } />
      </div>
      <p :if={Wiring.values(@cnc.db, @controller.id) == %{}} class="cnc-sub" id="no-wiring">
        Nothing is wired: {CNC.Boards.label(@controller.board)} has no pins to set.
      </p>
      <.part_editor
        :if={Wiring.values(@cnc.db, @controller.id) != %{}}
        part="wiring"
        target={@controller.id}
        values={Wiring.values(@cnc.db, @controller.id)}
        staged={staged_map(@staged, :wiring, @controller.id)}
        editing={@editing == {"wiring", @controller.id}}
        errors={@field_errors}
      />
      <div class="cnc-row">
        <UI.button
          id="wiring-history"
          phx-click="toggle"
          phx-value-key="history-wiring"
        >
          {if MapSet.member?(@showing, "history-wiring"), do: "Hide history", else: "History"}
        </UI.button>
      </div>
      <.revisions
        :if={MapSet.member?(@showing, "history-wiring")}
        id="history-wiring"
        entries={@wiring_history}
        prefix="w"
        expanded={@expanded}
        restore="restore_part"
        values={%{"part" => "wiring"}}
      />
    </section>
    """
  end

  defp tab_content(%{tab: :file} = assigns) do
    ~H"""
    <section class="cnc-set-group" id="tab-panel-file" aria-label="File">
      <p class="cnc-sub">
        {Configuration.file()} on {@controller.name}: its wiring, the build and the selected
        profile, written by the app.
      </p>

      <div :if={not @check.matches?} id="check-differences" class="cnc-warn-block">
        <p class="cnc-warn" id="check-differs">
          <%= if @check.override? do %>
            The controller loaded {@check.loaded} directly, not the app's file.
          <% else %>
            {@check.loaded} differs from the configuration{if not @check.written_by_app?,
              do: " (it wasn't written by the app)"}.
          <% end %>
        </p>
        <p class="cnc-sub">configuration → file:</p>
        <.diff_list diffs={check_diffs(@check)} id="check-diff" />
        <div class="cnc-row">
          <UI.button
            variant="primary"
            id="write-profile"
            phx-click="switch"
            phx-value-profile={@check.profile.id}
            disabled={@machine.moving?}
          >
            Write the configuration and restart
          </UI.button>
          <UI.button
            :if={not @check.override?}
            id="take-file"
            phx-click="take_file"
            disabled={@machine.moving?}
          >
            Keep the controller's values
          </UI.button>
        </div>
      </div>
      <p :if={@check.matches?} class="cnc-ok" id="check-ok">
        {@check.loaded} holds exactly the configuration.
      </p>

      <div :if={@drift != [] and @check.matches?} id="config-drift" class="cnc-warn-block">
        <p class="cnc-warn">
          The controller is running values that differ from the configuration (changed in the
          console, say):
        </p>
        <.diff_list diffs={for d <- @drift, do: %{path: d.path, from: d.profile, to: d.controller}} />
        <div class="cnc-row">
          <UI.button
            variant="primary"
            id="keep-drift"
            phx-click="keep_drift"
          >
            Keep them
          </UI.button>
          <UI.button type="button" id="put-back" phx-click="put_back">
            Put the configuration's back
          </UI.button>
        </div>
      </div>

      <div class="cnc-row">
        <UI.button type="button" id="view-file" phx-click="view">
          {if @viewing, do: "Hide #{@viewing}", else: "View #{active_file(assigns)}"}
        </UI.button>
      </div>
      <.yaml_view :if={@viewing} id="config-text" text={@text} />

      <form
        id="override-form"
        class="cnc-override"
        phx-change="validate_upload"
        phx-submit="review_override"
      >
        <h3 class="cnc-override-title">Use your own config</h3>
        <p class="cnc-sub">
          The escape hatch: a FluidNC config of your own in place of the app's. It replaces {Configuration.file()} (wiring included) and the controller restarts with it; you'll
          see the changes first.
        </p>
        <div class="cnc-override-ways">
          <label class="cnc-drop" phx-drop-target={@uploads.config_file.ref}>
            <span class="cnc-drop-title">Upload a file</span>
            <span class="cnc-dim">.yaml, or drop it here</span>
            <.live_file_input upload={@uploads.config_file} class="cnc-drop-input" />
            <span
              :for={entry <- @uploads.config_file.entries}
              class="cnc-drop-file"
              id="override-file"
            >
              {entry.client_name}
            </span>
          </label>
          <label class="cnc-paste">
            <span class="cnc-drop-title">Or paste it</span>
            <textarea
              name="paste"
              id="override-paste"
              rows="9"
              spellcheck="false"
              placeholder="name: My router&#10;axes:&#10;  x:&#10;    max_rate_mm_per_min: 3000"
            >{@paste}</textarea>
          </label>
        </div>
        <p :for={err <- upload_errors(@uploads.config_file)} class="cnc-set-error">
          {upload_error(err)}
        </p>
        <div class="cnc-row">
          <UI.button
            type="submit"
            id="review-override"
            disabled={
              (@uploads.config_file.entries == [] and String.trim(@paste) == "") or @machine.moving?
            }
          >
            Review changes
          </UI.button>
        </div>
      </form>
    </section>
    """
  end

  defp tab_content(%{tab: :history} = assigns) do
    ~H"""
    <section class="cnc-set-group" id="tab-panel-history" aria-label="History">
      <p class="cnc-sub">
        Every change written to {@controller.name}'s config, newest first: why, what changed,
        and the file as written. Restoring a version is a new version. The build, wiring and
        each profile keep their own histories in their tabs.
      </p>
      <p :if={@history == []} class="cnc-sub">No changes yet.</p>
      <.revisions
        :if={@history != []}
        id="controller-history"
        entries={@history}
        prefix="c"
        expanded={@expanded}
        restore="restore_file"
        files
      />
    </section>
    """
  end

  attr :check, :map, required: true
  attr :controller, :map, required: true
  attr :staged, :list, required: true

  # On every tab: which controller, which profile, and whether its file is in step.
  defp status_strip(assigns) do
    ~H"""
    <div class="cnc-status-strip" id="in-use">
      <span>
        <span class="cnc-dim">Controller</span>
        <strong id="config-controller">{@controller.name}</strong>
      </span>
      <span>
        <span class="cnc-dim">Profile</span> <strong>{@check.profile.name}</strong>
      </span>
      <.link
        patch={tab_path(:file)}
        id="status-file"
        class={if(@check.matches?, do: "cnc-ok", else: "cnc-warn")}
      >
        {cond do
          @check.matches? -> "In step with the controller"
          @check.override? -> "Controller loaded its own file"
          true -> "Controller's file differs"
        end}
      </.link>
    </div>
    """
  end

  attr :part, :string, required: true
  attr :target, :string, default: nil
  attr :values, :map, required: true
  attr :staged, :map, required: true
  attr :editing, :boolean, required: true
  attr :errors, :map, default: %{}

  # A part's values: the axis table for the usual ones, a list for the rest;
  # read-only, or (Edit) inputs that stage changes.
  defp part_editor(assigns) do
    assigns = assign(assigns, shown: Map.merge(assigns.values, assigns.staged))

    ~H"""
    <%= if @editing do %>
      <form id={"edit-#{@part}"} class="cnc-axes-form" phx-submit="stage">
        <input type="hidden" name="part" value={@part} />
        <input :if={@target} type="hidden" name="target" value={@target} />
        <.axes_table
          values={@shown}
          staged={@staged}
          editable
          id_prefix={"set-#{@part}"}
          errors={@errors}
        />
        <.values_list
          id={"values-#{@part}"}
          values={@values}
          staged={@staged}
          skip={axis_paths()}
          editable
          errors={@errors}
        />
        <.stage_buttons />
      </form>
    <% else %>
      <.axes_table values={@shown} staged={@staged} id_prefix={"view-#{@part}"} />
      <.values_list id={"values-#{@part}"} values={@values} staged={@staged} skip={axis_paths()} />
      <div class="cnc-row">
        <UI.button
          variant="primary"
          id={"edit-#{@part}-button"}
          phx-click="edit"
          phx-value-part={@part}
          phx-value-target={@target}
        >
          Edit
        </UI.button>
      </div>
    <% end %>
    """
  end

  defp stage_buttons(assigns) do
    ~H"""
    <p class="cnc-sub">
      Staged changes are applied together from the bar below; Apply now reviews just these.
    </p>
    <div class="cnc-row">
      <UI.button variant="primary" type="submit" name="intent" value="stage">
        Stage changes
      </UI.button>
      <UI.button type="submit" name="intent" value="now">Apply now</UI.button>
      <UI.button variant="quiet" type="button" phx-click="done_editing">Cancel</UI.button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :values, :map, required: true
  attr :staged, :map, default: %{}
  attr :skip, :list, default: []
  attr :editable, :boolean, default: false
  attr :errors, :map, default: %{}

  # Every value of a part (but those in the axis table), by path.
  defp values_list(assigns) do
    assigns =
      assign(assigns,
        rows:
          for(
            {path, value} <- Enum.sort(Map.merge(assigns.values, assigns.staged)),
            path not in assigns.skip,
            do: {path, value}
          )
      )

    ~H"""
    <details :if={@rows != []} class="cnc-values" id={@id} open={@editable}>
      <summary>{count_label(length(@rows))}</summary>
      <dl>
        <%= for {path, value} <- @rows do %>
          <dt><code>{path}</code></dt>
          <dd>
            <%= if @editable do %>
              <input
                name={"set[#{path}]"}
                value={shown(value)}
                autocomplete="off"
                spellcheck="false"
                aria-label={path}
                class={[Map.has_key?(@staged, path) && "is-staged", @errors[path] && "is-error"]}
                title={@errors[path]}
              />
            <% else %>
              <span class={[Map.has_key?(@staged, path) && "is-staged"]}>{shown(value)}</span>
            <% end %>
          </dd>
        <% end %>
      </dl>
    </details>
    """
  end

  # Review & apply: every staged change (or just some), grouped by part.
  defp review(assigns) do
    changes = reviewed(assigns)
    restart? = Enum.any?(changes, &(&1.part == :wiring and &1.target == assigns.controller.id))

    assigns =
      assign(assigns,
        groups: Enum.group_by(changes, &{&1.part, &1.target}),
        restart?: restart?,
        changes: changes
      )

    ~H"""
    <UI.dialog
      id="review-modal"
      title={"Apply #{count_label(length(@changes))}"}
      on_cancel="close_review"
    >
      <p class="ui-muted">
        <%= if @restart? do %>
          Values are set on the controller, then its file is written once and it restarts
          (wiring only changes at startup) and comes back locked.
        <% else %>
          Values are set on the controller straight away, then its file is written once.
        <% end %>
        Changes to a profile that isn't selected are only stored.
      </p>
      <div :for={{{part, target}, group} <- @groups} class="cnc-review-group">
        <h3 class="cnc-review-part">{part_label(assigns, part, target)}</h3>
        <ul class="cnc-changes">
          <li :for={c <- group} id={"review-" <> dom_id(Changes.key(c))}>
            <code>{c.path}</code>
            <span class="cnc-change-vals">
              <span class="cnc-diff-from">{shown(c.from) || "not set"}</span>
              → <strong class="cnc-diff-to">{shown(c.to)}</strong>
              <span
                :if={Changes.key(c) in @stale}
                class="cnc-warn"
                title="Changed elsewhere since it was staged"
              >
                changed since
              </span>
            </span>
            <UI.button
              variant="quiet"
              size="sm"
              phx-click="drop_change"
              phx-value-key={Changes.key(c)}
            >
              Remove
            </UI.button>
          </li>
        </ul>
      </div>
      <:actions>
        <UI.button variant="primary" id="apply-staged" phx-click="apply" disabled={@machine.moving?}>
          {if @restart?, do: "Apply and restart", else: "Apply"}
        </UI.button>
        <UI.button id="close-review" phx-click="close_review">Not yet</UI.button>
      </:actions>
    </UI.dialog>
    """
  end

  attr :dialog, :map, required: true
  attr :machine, :map, required: true

  # Approving one action from its diff.
  defp dialog(assigns) do
    ~H"""
    <UI.dialog id="approve-modal" title={@dialog.title} on_cancel="cancel_dialog">
      <p class="ui-muted">{@dialog.note}</p>
      <p :if={@dialog.diffs == []} class="ui-muted" id="approve-nothing">No values change.</p>
      <div :if={@dialog.diffs != []} class="cnc-modal-diffs">
        <p class="ui-muted">{@dialog.from_label} → {@dialog.to_label}:</p>
        <.diff_list diffs={@dialog.diffs} id="approve-diffs" />
      </div>
      <:actions>
        <UI.button variant="primary" id="approve" phx-click="approve" disabled={@machine.moving?}>
          {@dialog.approve}
        </UI.button>
        <UI.button id="cancel-approve" phx-click="cancel_dialog">Cancel</UI.button>
      </:actions>
    </UI.dialog>
    """
  end

  attr :values, :map, required: true
  attr :id_prefix, :string, required: true
  attr :staged, :map, default: %{}
  attr :editable, :boolean, default: false
  attr :layer, :atom, default: nil
  attr :errors, :map, default: %{}

  # The usual per-axis values, read-only or as inputs named set[path]; with
  # a layer, only its rows can be edited (and staged values show as such).
  defp axes_table(assigns) do
    ~H"""
    <table :if={axes(@values) != []} class="cnc-axes" id={"#{@id_prefix}-axes"}>
      <thead>
        <tr>
          <th></th>
          <th :for={a <- axes(@values)} scope="col">{String.upcase(a)}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={{field, label} <- axis_rows(@values)}>
          <th scope="row">
            {label}
            <span
              :if={Build.layer("axes/x/#{field}") == :build}
              class="cnc-layer"
              title="Part of the machine's build: the same for every profile"
            >
              build
            </span>
          </th>
          <td
            :for={a <- axes(@values)}
            class={[not editable_cell?(@editable, @layer, field) && "cnc-axes-value"]}
          >
            <%= if editable_cell?(@editable, @layer, field) do %>
              <input
                name={"set[axes/#{a}/#{field}]"}
                id={"#{@id_prefix}-#{a}-#{field}"}
                value={shown(@values["axes/#{a}/#{field}"])}
                inputmode="decimal"
                autocomplete="off"
                aria-label={"#{String.upcase(a)} #{label}"}
                class={[
                  Map.has_key?(@staged, "axes/#{a}/#{field}") && "is-staged",
                  @errors["axes/#{a}/#{field}"] && "is-error"
                ]}
                title={@errors["axes/#{a}/#{field}"]}
              />
            <% else %>
              <span
                id={"#{@id_prefix}-#{a}-#{field}"}
                class={[Map.has_key?(@staged, "axes/#{a}/#{field}") && "is-staged"]}
              >
                {shown(@values["axes/#{a}/#{field}"])}
              </span>
            <% end %>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp editable_cell?(false, _layer, _field), do: false
  defp editable_cell?(true, nil, _field), do: true
  defp editable_cell?(true, layer, field), do: Build.layer("axes/x/#{field}") == layer

  attr :id, :string, required: true
  attr :entries, :list, required: true
  attr :prefix, :string, required: true
  attr :expanded, :any, required: true
  attr :restore, :string, required: true
  attr :values, :map, default: %{}
  attr :files, :boolean, default: false

  # A history, newest first: each version with why, when and what changed;
  # open one for its diff, its file, and restoring it (a new version).
  defp revisions(assigns) do
    ~H"""
    <ol class="cnc-revs" id={@id}>
      <li :for={{e, i} <- Enum.with_index(@entries)} id={"#{@prefix}-v#{e.version}"} class="cnc-rev">
        <button
          type="button"
          class="cnc-rev-head"
          phx-click="toggle_rev"
          phx-value-key={"#{@prefix}-#{e.version}"}
          aria-expanded={to_string(MapSet.member?(@expanded, "#{@prefix}-#{e.version}"))}
        >
          <span class="cnc-rev-v">v{e.version}</span>
          <span class="cnc-rev-reason">{e.reason}</span>
          <span class="cnc-rev-meta">
            {changes_label(e.diff)} · {Calendar.strftime(e.at, "%b %-d %H:%M")} UTC
          </span>
        </button>
        <div :if={MapSet.member?(@expanded, "#{@prefix}-#{e.version}")} class="cnc-rev-body">
          <.diff_list :if={e.diff != []} diffs={e.diff} />
          <p :if={e.diff == []} class="cnc-sub">No values changed.</p>
          <div class="cnc-row">
            <UI.button
              :if={i > 0 and (not @files or is_binary(e.text))}
              phx-click={@restore}
              phx-value-i={i}
              {for {k, v} <- @values, into: %{}, do: {"phx-value-#{k}", v}}
            >
              Restore v{e.version}
            </UI.button>
            <UI.button
              :if={@files and is_binary(e.text)}
              variant="quiet"
              phx-click="toggle_rev"
              phx-value-key={"#{@prefix}-#{e.version}-file"}
            >
              {if MapSet.member?(@expanded, "#{@prefix}-#{e.version}-file"),
                do: "Hide file",
                else: "View file"}
            </UI.button>
          </div>
          <.yaml_view
            :if={
              @files and is_binary(e.text) and
                MapSet.member?(@expanded, "#{@prefix}-#{e.version}-file")
            }
            text={e.text}
          />
        </div>
      </li>
    </ol>
    """
  end

  attr :diffs, :list, required: true
  attr :id, :string, default: nil

  # Values that changed first; settings only one side has (one file spells
  # out what the other leaves to FluidNC's defaults) folded away.
  defp diff_list(assigns) do
    {changed, rest} = Enum.split_with(assigns.diffs, &(&1.from != nil and &1.to != nil))
    {added, removed} = Enum.split_with(rest, &(&1.from == nil))
    assigns = assign(assigns, changed: changed, added: added, removed: removed)

    ~H"""
    <div class="cnc-difflist" id={@id}>
      <ul :if={@changed != []} class="cnc-changes">
        <.diff_row :for={d <- @changed} d={d} list={@id} />
      </ul>
      <p :if={@changed == []} class="cnc-sub">No values changed.</p>
      <details :if={@added != []} class="cnc-diff-more">
        <summary>
          {values_count(length(@added))} added (FluidNC's defaults were in use for them)
        </summary>
        <ul class="cnc-changes">
          <.diff_row :for={d <- @added} d={d} list={@id} />
        </ul>
      </details>
      <details :if={@removed != []} class="cnc-diff-more">
        <summary>
          {values_count(length(@removed))} removed (left to FluidNC's defaults)
        </summary>
        <ul class="cnc-changes">
          <.diff_row :for={d <- @removed} d={d} list={@id} />
        </ul>
      </details>
    </div>
    """
  end

  attr :d, :map, required: true
  attr :list, :string, default: nil

  # Rows get ids only in a list with one (a value can be in several lists).
  defp diff_row(assigns) do
    ~H"""
    <li id={@list && "#{@list}-" <> String.replace(@d.path, ~r/[^A-Za-z0-9_-]/, "-")}>
      <code>{@d.path}</code>
      <span class="cnc-change-vals">
        <span class="cnc-diff-from">{shown(@d.from) || "not set"}</span>
        → <strong class="cnc-diff-to">{shown(@d.to) || "not set"}</strong>
      </span>
    </li>
    """
  end

  defp values_count(1), do: "1 value"
  defp values_count(n), do: "#{n} values"

  defp changes_label([]), do: "no values changed"

  defp changes_label(diff) do
    changed = Enum.count(diff, &(&1.from != nil and &1.to != nil))
    other = length(diff) - changed

    case {changed, other} do
      {c, 0} -> "#{values_count(c)} changed"
      {0, o} -> "#{values_count(o)} added or removed"
      {c, o} -> "#{values_count(c)} changed, #{o} added or removed"
    end
  end

  attr :profile, :map, required: true

  defp rename_form(assigns) do
    ~H"""
    <form id={"rename-#{@profile.id}"} class="cnc-rename" phx-submit="save_name">
      <input type="hidden" name="profile" value={@profile.id} />
      <input name="name" value={@profile.name} autocomplete="off" aria-label="Profile name" />
      <UI.button type="submit">Save</UI.button>
      <UI.button variant="quiet" type="button" phx-click="cancel_rename">
        Cancel
      </UI.button>
    </form>
    """
  end

  ## Helpers

  defp tabs, do: @tabs

  defp tab_path(:profiles), do: ~p"/configuration"
  defp tab_path(tab), do: "/configuration/#{tab}"

  # Staged changes that belong to a tab (a badge on it).
  defp staged_in(staged, :profiles), do: Enum.count(staged, &(&1.part == :profile))
  defp staged_in(staged, :build), do: Enum.count(staged, &(&1.part == :build))
  defp staged_in(staged, :wiring), do: Enum.count(staged, &(&1.part == :wiring))
  defp staged_in(_staged, _tab), do: 0

  defp staged_summary(assigns) do
    assigns.staged
    |> Enum.group_by(&{&1.part, &1.target})
    |> Enum.map_join(", ", fn {{part, target}, group} ->
      "#{part_label(assigns, part, target)} #{length(group)}"
    end)
  end

  defp part_label(_assigns, :build, _), do: "build"

  defp part_label(%{controller: c}, :wiring, id),
    do: if(c && c.id == id, do: "wiring", else: "wiring (another controller)")

  defp part_label(%{profiles: profiles}, :profile, pid),
    do: "profile " <> (Enum.find_value(profiles, &(&1.id == pid && &1.name)) || "?")

  defp count_label(1), do: "1 value"
  defp count_label(n), do: "#{n} values"

  # Staged values of one part, path => new value.
  defp staged_map(staged, part, target),
    do: for(c <- staged, c.part == part, c.target == target, into: %{}, do: {c.path, c.to})

  defp staged_to(%{staged: staged}, part, target, path),
    do:
      Enum.find_value(
        staged,
        &(&1.part == part and &1.target == target and &1.path == path and &1.to)
      )

  # A part's values as stored (what a staged change starts from).
  defp part_values(%{cnc: cnc}, :build, _), do: Build.values(cnc.db)
  defp part_values(%{cnc: cnc}, :wiring, id), do: Wiring.values(cnc.db, id)

  defp part_values(%{profiles: profiles}, :profile, pid),
    do: Enum.find_value(profiles, %{}, &(&1.id == pid && &1.values))

  defp axis_paths, do: for(a <- ~w(x y z a b c), {f, _} <- @axis_fields, do: "axes/#{a}/#{f}")

  # The selected one first.
  defp ordered_profiles(profiles, check),
    do: Enum.sort_by(profiles, &(not selected?(check, &1)))

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  # The check's differences as a diff: from what the configuration says to
  # what the file holds.
  defp check_diffs(check),
    do: for(d <- check.differences, do: %{path: d.path, from: d.profile, to: d.controller})

  # A controller in use and the machine ready for commands.
  defp ready?(assigns),
    do:
      assigns.controller != nil and assigns.machine.connected? and
        assigns.machine.state in [:alarm, :idle]

  # The configuration is the machine's; the controller is whichever is in use.
  defp refresh_active(socket),
    do: assign(socket, controller: Controllers.active(socket.assigns.cnc.controllers))

  defp load(socket) do
    %{cnc: cnc, controller: c} = socket.assigns

    if connected?(socket) and ready?(socket.assigns) do
      with :ok <- Configuration.ensure(cnc.machine, cnc.db, c),
           {:ok, check} <- Configuration.check(cnc.machine, cnc.db, c),
           {:ok, running} <- FluidNC.running(cnc.machine),
           {:ok, drift} <- Configuration.drift(cnc.machine, cnc.db, c) do
        running = Values.parse(running)

        socket
        |> assign(
          profiles: Profiles.list(cnc.db),
          build_history: Build.history(cnc.db),
          wiring_history: Wiring.history(cnc.db, c.id),
          check: check,
          running: Map.new(running),
          current: Configuration.expected(cnc.db, c, check.profile),
          drift: drift,
          wiring: Configuration.wiring_check(c.board, running),
          history: History.list(cnc.db, c.id),
          staged: Changes.list(cnc.db)
        )
        |> mark_stale()
      else
        {:error, reason} -> assign(socket, error: error_text(reason))
      end
    else
      socket
    end
  end

  defp default_from(%{check: %{profile: %{id: id}}}), do: id
  defp default_from(%{profiles: [p | _]}), do: p.id
  defp default_from(_), do: :board

  defp active_file(%{check: %{loaded: file}}), do: file
  defp active_file(_), do: nil

  defp selected?(%{profile: %{id: id}}, %{id: id}), do: true
  defp selected?(_, _), do: false

  # Axes with any of the usual values, and the rows any of them has (a
  # controller shows only what its config holds: the fake sim has no steps).
  defp axes(values) do
    for a <- ~w(x y z a b c),
        Enum.any?(@axis_fields, fn {f, _} -> Map.has_key?(values, "axes/#{a}/#{f}") end),
        do: a
  end

  defp axis_rows(values) do
    for {f, _} = row <- @axis_fields,
        Enum.any?(axes(values), &Map.has_key?(values, "axes/#{&1}/#{f}")),
        do: row
  end

  # 2500.000000 → 2500, 0.500 → 0.5; text stays as it is.
  defp shown(nil), do: nil

  defp shown(value) do
    case Float.parse(value) do
      {_, ""} ->
        if String.contains?(value, "."),
          do: value |> String.trim_trailing("0") |> String.trim_trailing("."),
          else: value

      _ ->
        value
    end
  end

  defp same_value?(nil, _), do: false
  defp same_value?(a, b), do: Values.same?(a, String.trim(b))

  defp upload_error(:too_large), do: "That file is over 256 KB: not a config file?"
  defp upload_error(:too_many_files), do: "One file at a time."
  defp upload_error(err), do: "Upload failed (#{inspect(err)})."

  defp waiting_text(:disconnected), do: "Not connected yet: waiting for the controller."
  defp waiting_text(:connecting), do: "Connecting…"
  defp waiting_text(:uploading), do: "Sending a file to the controller…"
  defp waiting_text(_), do: "The machine is moving: the configuration is available once it stops."

  defp dom_id(name), do: String.replace(name, ~r/[^A-Za-z0-9_-]/, "-")

  defp error_text(:wrong_part),
    do: "That value belongs to another part of the configuration: change it in its tab."

  defp error_text(:name_required), do: "Give the profile a name."
  defp error_text(:exists), do: "There's already one with that name."
  defp error_text(:in_use), do: "That's the selected profile: switch to another first."
  defp error_text(:no_profile), do: "No profile is selected."

  defp error_text(:not_profile_value),
    do:
      "That's part of the machine's build or the wiring, the same for every profile: change it in the current configuration."

  defp error_text(:not_editable), do: "That's a name in the file, not a value."
  defp error_text(:nothing_to_use), do: "Choose a file, or paste a config."
  defp error_text(:no_file), do: "That version has no file (a live change)."
  defp error_text(:not_yaml), do: "Choose a FluidNC config file (.yaml or .yml)."
  defp error_text(:not_a_config), do: "That file doesn't look like a FluidNC config."
  defp error_text(:selected), do: "That's the current profile: edit it above."
  defp error_text(:not_a_number), do: "That needs a number."

  defp error_text(:override),
    do: "The controller loaded a file directly: switch to a profile to change values."

  defp error_text({:not_written, reason}),
    do: "Applied, but writing the profile's file failed: #{error_text(reason)}"

  defp error_text(:unknown_setting), do: "The controller has no such value."
  defp error_text(:invalid_setting), do: "A value's path looks like axes/x/max_rate_mm_per_min."
  defp error_text(:invalid_value), do: "Enter a value (no = or line breaks)."
  defp error_text(:no_active_file), do: "The controller doesn't say which file it loaded."

  defp error_text(:wiring),
    do: "That's wiring (pins, stepping): it comes from the board, not a profile."

  defp error_text({:not_applied, why}), do: "The controller didn't apply it (#{why})."
  defp error_text(:busy), do: "The controller is busy: try again in a moment."
  defp error_text(:canceled), do: "The controller cancelled the transfer."
  defp error_text(:timeout), do: "The controller stopped answering during the transfer."
  defp error_text(:too_many_retries), do: "The transfer kept failing (a noisy link?). Try again."
  defp error_text(:not_supported), do: "This link can't send files."
  defp error_text(:invalid_name), do: "Use letters, digits, - and _ for a file name."
  defp error_text(:active), do: "That's the file the controller loads: load another first."
  defp error_text(:not_found), do: "That isn't there any more."
  defp error_text(:moving), do: "The machine is moving: stop it first."
  defp error_text(:overridden), do: "CNC_LINK is set, so the machine uses that link instead."
  defp error_text(:reset), do: "The controller reset before answering. Try again."
  defp error_text({:invalid_state, _}), do: "The controller is busy: try again once it's idle."
  defp error_text(code) when is_integer(code), do: "The controller refused it (error #{code})."
  defp error_text(other), do: "That didn't work: #{inspect(other)}."
end
