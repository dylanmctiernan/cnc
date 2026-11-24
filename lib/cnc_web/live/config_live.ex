defmodule CNCWeb.ConfigLive do
  @moduledoc """
  One controller's configuration (`/controllers/:id/configuration`), by
  profile (`CNC.Controllers.Profiles`): which profile is in use (from the
  controller), switching and making profiles, changing the settings of the
  one in use (applied straight away), what the controller runs that the
  profile doesn't (keep or put back), the wiring check, and under Advanced
  the files themselves (view, load one directly as an override, history).
  Needs that controller connected; otherwise it offers to connect it.
  """
  use CNCWeb, :live_view

  on_mount CNCWeb.Pin

  alias CNC.{Boards, Controllers, Machine}
  alias CNC.Configuration
  alias CNC.Configuration.{Build, FluidNC, History, Profiles, Values, Wiring}

  import CNCWeb.YamlView, only: [yaml_view: 1]

  @axis_fields [
    {"steps_per_mm", "Steps per mm"},
    {"max_rate_mm_per_min", "Max rate (mm/min)"},
    {"acceleration_mm_per_sec2", "Acceleration (mm/s²)"},
    {"max_travel_mm", "Max travel (mm)"}
  ]

  @impl true
  def mount(%{"id" => id}, session, socket) do
    cnc = CNCWeb.Instance.from_session(session)

    if connected?(socket) do
      Machine.subscribe(cnc.topic)
      Controllers.subscribe(cnc.controllers_topic)
    end

    case Enum.find(Controllers.list(cnc.controllers), &(&1.id == id)) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "There's no controller #{id}.")
         |> push_navigate(to: ~p"/controllers")}

      controller ->
        {:ok,
         socket
         |> assign(page_title: "#{controller.name} configuration", cnc: cnc)
         |> assign(controller: controller, machine: Machine.status(cnc.machine))
         |> assign(profiles: [], check: nil, settings: %{}, paths: [], drift: [])
         |> assign(wiring: %{checked: 0, differences: []}, files: [], history: [])
         |> assign(viewing: nil, text: nil, renaming: nil, error: nil)
         |> assign(working: nil, field_errors: %{}, other: %{"path" => "", "value" => ""})
         |> assign(new: %{"name" => "", "from" => ""}, advanced?: false)
         |> assign(editing_current?: false, editing_profile: nil, showing_profile: nil)
         |> assign(diffing_profile: nil, pending: nil)
         |> assign(expanded: MapSet.new(), history_for: nil, paste: "")
         |> assign(build_history: [], wiring_history: [], current: %{})
         |> allow_upload(:config_file, accept: :any, max_entries: 1, max_file_size: 256_000)
         |> refresh_active()
         |> maybe_load()}
    end
  end

  @impl true
  def handle_info({:machine, machine}, socket) do
    was_ready? = ready?(socket.assigns)
    socket = assign(socket, machine: machine)

    # Came back (connected, or after a restart): read everything again.
    if ready?(socket.assigns) and not was_ready?,
      do: {:noreply, socket |> assign(working: nil) |> maybe_load()},
      else: {:noreply, socket}
  end

  def handle_info({:controllers, _}, socket), do: {:noreply, refresh_active(socket)}

  @impl true
  def handle_event("connect", _, socket) do
    case Controllers.select(socket.assigns.cnc.controllers, socket.assigns.controller.id) do
      :ok -> {:noreply, socket |> assign(error: nil) |> refresh_active()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  ## Profiles

  ## Asking first: what would change, approved in a dialog

  def handle_event("switch", %{"profile" => pid}, socket) do
    %{profiles: profiles, check: check} = socket.assigns

    case Enum.find(profiles, &(&1.id == pid)) do
      nil ->
        {:noreply, assign(socket, error: error_text(:not_found))}

      target ->
        if check && selected?(check, target) do
          ask(socket,
            title: "Write #{target.name} to the controller",
            note:
              "Its config file becomes #{target.name}; the controller restarts and comes back locked. What the file holds now goes into the history.",
            approve: "Write and restart",
            diffs:
              for(d <- check.differences, do: %{path: d.path, from: d.controller, to: d.profile}),
            from_label: "file",
            to_label: target.name,
            action: {:switch, pid}
          )
        else
          ask(socket,
            title: "Switch to #{target.name}",
            note:
              "It's written to the controller as its config file; the controller restarts and comes back locked.",
            approve: "Switch and restart",
            diffs: if(check, do: Profiles.diff(check.profile, target), else: []),
            from_label: check && check.profile.name,
            to_label: target.name,
            action: {:switch, pid}
          )
        end
    end
  end

  # The axis table: every value that differs from the profile.
  def handle_event("apply_axes", %{"set" => values}, socket) do
    # Against all three parts: build rows are in the table too
    current = socket.assigns.current

    changes =
      for {path, value} <- values,
          String.trim(value) != "",
          not same_value?(current[path], value),
          do: {path, String.trim(value)}

    ask_apply(socket, changes, nil)
  end

  def handle_event(
        "apply_other",
        %{"other" => %{"path" => path, "value" => value} = other},
        socket
      ) do
    ask_apply(assign(socket, other: other), [{clean_path(path), String.trim(value)}], other)
  end

  def handle_event("save_profile", %{"profile" => pid, "set" => values}, socket) do
    profile = Enum.find(socket.assigns.profiles, &(&1.id == pid))
    current = (profile && profile.values) || %{}

    changes =
      for {path, value} <- values,
          String.trim(value) != "",
          not same_value?(current[path], value),
          do: {path, String.trim(value)}

    if changes == [] do
      {:noreply, assign(socket, editing_profile: nil, field_errors: %{})}
    else
      ask(socket,
        title: "Save #{profile.name}",
        note:
          "Saved in the profile only: the controller gets these when you switch to #{profile.name}.",
        approve: "Save",
        diffs: for({path, v} <- changes, do: %{path: path, from: current[path], to: v}),
        from_label: "now",
        to_label: "saved",
        action: {:save_profile, pid, changes}
      )
    end
  end

  def handle_event("take_file", _, socket) do
    %{cnc: cnc, controller: c, check: check} = socket.assigns

    case Configuration.drift(cnc.machine, cnc.db, c) do
      {:ok, drift} ->
        ask(socket,
          title: "Keep the controller's values in #{check.profile.name}",
          note:
            "What the controller runs now becomes #{check.profile.name}; then it's written as the config file and the controller restarts.",
          approve: "Keep, write and restart",
          diffs: for(d <- drift, do: %{path: d.path, from: d.profile, to: d.controller}),
          from_label: check.profile.name,
          to_label: "running",
          action: :take_file
        )

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("keep_drift", _, socket) do
    %{drift: drift, check: check} = socket.assigns

    ask(socket,
      title: "Keep the running values in #{check.profile.name}",
      note: "They go into the profile and its config file. Nothing restarts.",
      approve: "Keep",
      diffs: for(d <- drift, do: %{path: d.path, from: d.profile, to: d.controller}),
      from_label: check.profile.name,
      to_label: "running",
      action: :keep_drift
    )
  end

  def handle_event("put_back", _, socket) do
    %{drift: drift, check: check} = socket.assigns

    ask(socket,
      title: "Put #{check.profile.name}'s values back",
      note: "Set on the controller straight away. Nothing restarts.",
      approve: "Put back",
      diffs: for(d <- drift, do: %{path: d.path, from: d.controller, to: d.profile}),
      from_label: "running",
      to_label: check.profile.name,
      action: :put_back
    )
  end

  def handle_event("cancel_pending", _, socket), do: {:noreply, assign(socket, pending: nil)}

  def handle_event("approve", _, %{assigns: %{pending: nil}} = socket), do: {:noreply, socket}

  def handle_event("approve", _, socket) do
    action = socket.assigns.pending.action
    run(assign(socket, pending: nil), action)
  end

  def handle_event("new_change", %{"new" => new}, socket),
    do: {:noreply, assign(socket, new: new)}

  def handle_event("create", %{"new" => %{"name" => name} = new}, socket) do
    %{cnc: cnc, controller: c} = socket.assigns

    from =
      case new["from"] do
        "board" -> :board
        nil -> default_from(socket.assigns)
        "" -> default_from(socket.assigns)
        pid -> pid
      end

    case Profiles.create(cnc.db, name, c.board, from) do
      {:ok, p} ->
        {:noreply,
         socket
         |> assign(new: %{"name" => "", "from" => ""}, error: nil)
         |> put_flash(:info, "Made #{p.name}. Switch to it to use it.")
         |> maybe_load()}

      {:error, reason} ->
        {:noreply, assign(socket, new: new, error: error_text(reason))}
    end
  end

  def handle_event("rename", %{"profile" => pid}, socket),
    do: {:noreply, assign(socket, renaming: pid)}

  def handle_event("cancel_rename", _, socket), do: {:noreply, assign(socket, renaming: nil)}

  def handle_event("save_name", %{"profile" => pid, "name" => name}, socket) do
    %{cnc: cnc} = socket.assigns

    case Profiles.rename(cnc.db, pid, name) do
      :ok -> {:noreply, socket |> assign(renaming: nil, error: nil) |> maybe_load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("delete_profile", %{"profile" => pid}, socket) do
    %{cnc: cnc} = socket.assigns

    case Profiles.delete(cnc.db, pid) do
      :ok -> {:noreply, socket |> assign(error: nil) |> maybe_load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  ## Settings of the profile in use

  # The axis table: every value that differs from what's running is set.
  def handle_event("edit_current", _, socket),
    do: {:noreply, assign(socket, editing_current?: true, field_errors: %{})}

  def handle_event("cancel_edit_current", _, socket),
    do: {:noreply, assign(socket, editing_current?: false, field_errors: %{})}

  # The axis table: every value that differs from the profile is set.
  def handle_event("show_all", %{"profile" => pid}, socket) do
    showing = if socket.assigns.showing_profile == pid, do: nil, else: pid
    {:noreply, assign(socket, showing_profile: showing)}
  end

  def handle_event("diff_profile", %{"profile" => pid}, socket) do
    diffing = if socket.assigns.diffing_profile == pid, do: nil, else: pid
    {:noreply, assign(socket, diffing_profile: diffing)}
  end

  def handle_event("edit_profile", %{"profile" => pid}, socket),
    do: {:noreply, assign(socket, editing_profile: pid, field_errors: %{})}

  def handle_event("cancel_edit_profile", _, socket),
    do: {:noreply, assign(socket, editing_profile: nil, field_errors: %{})}

  def handle_event("other_change", %{"other" => other}, socket),
    do: {:noreply, assign(socket, other: other)}

  ## Files (advanced)

  # Kept open across updates (a <details> opened in the browser alone would
  # close on the next render).
  def handle_event("toggle_advanced", _, socket),
    do: {:noreply, update(socket, :advanced?, &(not &1))}

  def handle_event("view", %{"name" => name}, socket) do
    case FluidNC.show(machine(socket), name) do
      {:ok, text} -> {:noreply, assign(socket, viewing: name, text: text, error: nil)}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("close_view", _, socket),
    do: {:noreply, assign(socket, viewing: nil, text: nil)}

  def handle_event("validate_upload", params, socket),
    do: {:noreply, assign(socket, paste: Map.get(params, "paste", socket.assigns.paste))}

  # An override: a file of your own (uploaded, or pasted) in place of the
  # profile's. Shown as a diff first.
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
          "It replaces #{Configuration.file()} (wiring included) and the controller restarts with it. Recorded in the history as: #{reason}.",
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

  def handle_event("toggle_rev", %{"key" => key}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, assign(socket, expanded: expanded)}
  end

  def handle_event("profile_history", %{"profile" => pid}, socket) do
    open = if socket.assigns.history_for == pid, do: nil, else: pid
    {:noreply, assign(socket, history_for: open)}
  end

  # A controller revision back: its file, written as a new revision.
  def handle_event("restore_config", %{"i" => i}, socket) do
    %{history: history, check: check} = socket.assigns

    case Enum.at(history, String.to_integer(i)) do
      %{text: text, version: v} = rev when is_binary(text) ->
        ask(socket,
          title: "Restore the controller's config to v#{v}",
          note:
            "#{rev.file} gets v#{v}'s file back (a new version, \"Restored v#{v}\"); the controller restarts with it.",
          approve: "Restore and restart",
          diffs: Values.diff_texts(check && check.text, text),
          from_label: "now",
          to_label: "v#{v}",
          action: {:restore_config, String.to_integer(i)}
        )

      _ ->
        {:noreply, assign(socket, error: error_text(:not_found))}
    end
  end

  # The build or the wiring back to an earlier version: written, restarts.
  def handle_event("restore_layer", %{"profile" => layer, "i" => i}, socket)
      when layer in ["build", "wiring"] do
    %{cnc: cnc, controller: c} = socket.assigns
    i = String.to_integer(i)

    {history, now} =
      if layer == "build",
        do: {socket.assigns.build_history, Build.values(cnc.db)},
        else: {socket.assigns.wiring_history, Wiring.values(cnc.db, c.id)}

    case Enum.at(history, i) do
      %{values: values, version: v} ->
        ask(socket,
          title: "Restore the #{layer} to v#{v}",
          note:
            "A new version of the #{layer} (\"Restored v#{v}\"), written to the controller, which restarts.",
          approve: "Restore and restart",
          diffs: Values.diff_maps(now, values),
          from_label: "now",
          to_label: "v#{v}",
          action: {:restore_layer, String.to_existing_atom(layer), i}
        )

      nil ->
        {:noreply, assign(socket, error: error_text(:not_found))}
    end
  end

  # A profile revision back: a new revision of the profile.
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
            do:
              "A new version of #{profile.name} (\"Restored v#{rev.version}\"), written to the controller, which restarts.",
            else:
              "A new version of #{profile.name} (\"Restored v#{rev.version}\"). Stored only: the controller gets it when you switch to it."
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

  # An earlier version back into its file; for the controller's file, a
  # restart loads it (then it shows as differing from the profile).
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="cnc-page">
        <header class="cnc-bar">
          <.link navigate={~p"/controllers"} class="cnc-btn" id="back-to-controllers">
            Controllers
          </.link>
          <h1 class="cnc-page-title">{@controller.name} configuration</h1>
          <div class={"cnc-state cnc-state--#{@machine.state}"} role="status">
            {state_word(@machine.state)}
          </div>
        </header>

        <main class="cnc-settings">
          <p class="cnc-sub cnc-settings-intro">
            A profile is a set of this controller's settings. The selected one is written to
            the controller, with the board's wiring, as its config file. Make profiles to try
            variations and switch between them (the controller restarts and comes back
            locked). Changes to a setting apply straight away.
          </p>

          <p :if={@error} id="config-error" class="cnc-set-error">{@error}</p>

          <%= cond do %>
            <% not @active? -> %>
              <section class="cnc-set-group" id="config-not-connected">
                <p class="cnc-note">
                  {@controller.name} isn't the controller in use. Connect it to see and change
                  its configuration.
                </p>
                <div class="cnc-row">
                  <button
                    type="button"
                    id="config-connect"
                    class="cnc-btn cnc-btn--primary"
                    phx-click="connect"
                    disabled={@machine.moving?}
                  >
                    Connect {@controller.name}
                  </button>
                </div>
              </section>
            <% @working -> %>
              <p class="cnc-note" id="config-working">{@working}</p>
            <% not ready?(assigns) -> %>
              <p class="cnc-note" id="config-waiting">{waiting_text(@machine.state)}</p>
            <% true -> %>
              <section
                :if={@check}
                class="cnc-set-group"
                id="current"
                aria-label="Current settings"
              >
                <h2 class="cnc-h">Current settings</h2>
                <div class="cnc-ctl-card is-active" id={"profile-#{@check.profile.id}"}>
                  <div class="cnc-ctl-card-head">
                    <h3 :if={@renaming != @check.profile.id} class="cnc-ctl-name" id="current-name">
                      {@check.profile.name}
                    </h3>
                    <.rename_form :if={@renaming == @check.profile.id} profile={@check.profile} />
                    <span class="cnc-ctl-tag">Selected</span>
                  </div>
                  <div id="in-use">
                    <p class="cnc-in-use">
                      Profile <strong>{@check.profile.name}</strong>
                      <%= cond do %>
                        <% @check.matches? -> %>
                          <span class="cnc-ok" id="check-ok">
                            is what the controller runs ({@check.loaded} matches it).
                          </span>
                        <% @check.override? -> %>
                          <span class="cnc-warn" id="check-override">
                            is selected, but the controller loaded {@check.loaded} directly.
                          </span>
                        <% true -> %>
                          <span class="cnc-warn" id="check-differs">
                            is selected, but the controller's {@check.loaded} differs from it{if not @check.written_by_app?,
                              do: " (it wasn't written by the app)"}.
                          </span>
                      <% end %>
                    </p>
                    <div :if={not @check.matches?} id="check-differences" class="cnc-warn-block">
                      <p class="cnc-sub">configuration → file:</p>
                      <.diff_list diffs={check_diffs(@check)} id="check-diff" />
                      <div class="cnc-row">
                        <button
                          type="button"
                          id="write-profile"
                          class="cnc-btn cnc-btn--primary"
                          phx-click="switch"
                          phx-value-profile={@check.profile.id}
                          disabled={@machine.moving?}
                        >
                          Write {@check.profile.name} and restart
                        </button>
                        <button
                          :if={not @check.override?}
                          type="button"
                          id="take-file"
                          class="cnc-btn"
                          phx-click="take_file"
                        >
                          Keep the controller's values in {@check.profile.name}
                        </button>
                      </div>
                    </div>
                  </div>

                  <%!-- Only when the file is the profile's: otherwise the file check above
                       already explains why the running values differ. --%>
                  <div :if={@drift != [] and @check.matches?} id="config-drift" class="cnc-warn-block">
                    <p class="cnc-warn">
                      The controller is running values that differ from {@check.profile.name} (changed in the console, say):
                    </p>
                    <ul class="cnc-changes">
                      <li :for={d <- @drift} id={"drift-#{dom_id(d.path)}"}>
                        <code>{d.path}</code>
                        <span class="cnc-change-vals">
                          profile {shown(d.profile)}, running <strong>{shown(d.controller)}</strong>
                        </span>
                      </li>
                    </ul>
                    <div class="cnc-row">
                      <button
                        type="button"
                        id="keep-drift"
                        class="cnc-btn cnc-btn--primary"
                        phx-click="keep_drift"
                      >
                        Keep them in {@check.profile.name}
                      </button>
                      <button type="button" id="put-back" class="cnc-btn" phx-click="put_back">
                        Put the profile's back
                      </button>
                    </div>
                  </div>

                  <%= if @editing_current? and not @check.override? do %>
                    <form id="axes-form" class="cnc-axes-form" phx-submit="apply_axes">
                      <.axes_table
                        values={@current}
                        editable
                        id_prefix="set"
                        errors={@field_errors}
                      />
                      <p :for={{path, msg} <- @field_errors} class="cnc-set-error">
                        {path}: {msg}
                      </p>
                      <div class="cnc-row">
                        <button type="submit" class="cnc-btn cnc-btn--primary" id="apply-axes">
                          Apply
                        </button>
                        <button type="button" class="cnc-btn" phx-click="cancel_edit_current">
                          Done
                        </button>
                      </div>
                    </form>

                    <form
                      id="other-form"
                      class="cnc-ctl-form"
                      phx-change="other_change"
                      phx-submit="apply_other"
                    >
                      <h3 class="cnc-sub">Any other setting</h3>
                      <div class="cnc-other-row">
                        <label class="cnc-ctl-field">
                          <span>Setting</span>
                          <input
                            name="other[path]"
                            value={@other["path"]}
                            list="setting-paths"
                            placeholder="axes/x/homing/seek_mm_per_min"
                            autocomplete="off"
                            spellcheck="false"
                          />
                        </label>
                        <label class="cnc-ctl-field">
                          <span>
                            Value<span :if={@settings[clean_path(@other["path"])]} class="cnc-now">
                              (now {shown(@settings[clean_path(@other["path"])])})
                            </span>
                          </span>
                          <input name="other[value]" value={@other["value"]} autocomplete="off" />
                        </label>
                      </div>
                      <datalist id="setting-paths">
                        <option :for={p <- @paths} value={p} />
                      </datalist>
                      <div class="cnc-row">
                        <button type="submit" class="cnc-btn">Apply</button>
                      </div>
                    </form>
                  <% else %>
                    <.axes_table values={@current} id_prefix="current" />
                    <div class="cnc-row">
                      <button
                        :if={not @check.override?}
                        type="button"
                        id="edit-current"
                        class="cnc-btn cnc-btn--primary"
                        phx-click="edit_current"
                      >
                        Edit
                      </button>
                      <button
                        type="button"
                        class="cnc-btn"
                        id="show-all-current"
                        phx-click="show_all"
                        phx-value-profile={@check.profile.id}
                      >
                        {if @showing_profile == @check.profile.id, do: "Hide", else: "View"}
                      </button>
                      <button
                        type="button"
                        class="cnc-btn"
                        id="current-history"
                        phx-click="profile_history"
                        phx-value-profile={@check.profile.id}
                      >
                        {if @history_for == @check.profile.id, do: "Hide history", else: "History"}
                      </button>
                      <button
                        type="button"
                        class="cnc-btn"
                        id="build-history"
                        phx-click="profile_history"
                        phx-value-profile="build"
                      >
                        {if @history_for == "build", do: "Hide build history", else: "Build history"}
                      </button>
                      <button
                        :if={@wiring_history != []}
                        type="button"
                        class="cnc-btn"
                        id="wiring-history"
                        phx-click="profile_history"
                        phx-value-profile="wiring"
                      >
                        {if @history_for == "wiring",
                          do: "Hide wiring history",
                          else: "Wiring history"}
                      </button>
                      <button
                        type="button"
                        class="cnc-btn cnc-btn--quiet"
                        phx-click="rename"
                        phx-value-profile={@check.profile.id}
                      >
                        Rename
                      </button>
                    </div>
                    <.revisions
                      :if={@history_for == "build"}
                      id="history-build"
                      entries={@build_history}
                      prefix="b"
                      expanded={@expanded}
                      restore="restore_layer"
                      profile="build"
                    />
                    <.revisions
                      :if={@history_for == "wiring"}
                      id="history-wiring"
                      entries={@wiring_history}
                      prefix="w"
                      expanded={@expanded}
                      restore="restore_layer"
                      profile="wiring"
                    />
                    <.yaml_view
                      :if={@showing_profile == @check.profile.id}
                      id="current-yaml"
                      text={Configuration.render(@cnc.db, @controller, @check.profile)}
                    />
                    <.revisions
                      :if={@history_for == @check.profile.id}
                      id={"history-#{@check.profile.id}"}
                      entries={@check.profile.history}
                      prefix={"p-#{@check.profile.id}"}
                      expanded={@expanded}
                      restore="restore_profile"
                      profile={@check.profile.id}
                    />
                  <% end %>
                </div>
              </section>

              <section class="cnc-set-group" aria-label="Other profiles">
                <h2 class="cnc-h">Other profiles</h2>
                <p :if={others(@profiles, @check) == []} class="cnc-sub" id="no-other-profiles">
                  None yet. Make one to try a variation: it starts as a copy, and switching to
                  it writes it to the controller.
                </p>
                <ul class="cnc-ctls" id="profiles">
                  <li
                    :for={p <- others(@profiles, @check)}
                    id={"profile-#{p.id}"}
                    class="cnc-ctl-card"
                  >
                    <div class="cnc-ctl-card-head">
                      <h3 :if={@renaming != p.id} class="cnc-ctl-name">{p.name}</h3>
                      <.rename_form :if={@renaming == p.id} profile={p} />
                    </div>

                    <form
                      :if={@editing_profile == p.id}
                      id={"edit-profile-#{p.id}"}
                      class="cnc-axes-form"
                      phx-submit="save_profile"
                    >
                      <input type="hidden" name="profile" value={p.id} />
                      <.axes_table
                        values={Configuration.expected(@cnc.db, @controller, p)}
                        editable
                        only_profile
                        id_prefix={"p-#{p.id}"}
                        errors={@field_errors}
                      />
                      <p :for={{path, msg} <- @field_errors} class="cnc-set-error">
                        {path}: {msg}
                      </p>
                      <p class="cnc-sub">
                        Saved in the profile; the controller gets them when you switch to it.
                      </p>
                      <div class="cnc-row">
                        <button type="submit" class="cnc-btn cnc-btn--primary">Save</button>
                        <button type="button" class="cnc-btn" phx-click="cancel_edit_profile">
                          Cancel
                        </button>
                      </div>
                    </form>

                    <div :if={@editing_profile != p.id and @renaming != p.id} class="cnc-row">
                      <button
                        type="button"
                        class="cnc-btn cnc-btn--primary"
                        phx-click="switch"
                        phx-value-profile={p.id}
                        disabled={@machine.moving?}
                      >
                        Switch to this
                      </button>
                      <button
                        type="button"
                        class="cnc-btn"
                        phx-click="show_all"
                        phx-value-profile={p.id}
                      >
                        {if @showing_profile == p.id, do: "Hide", else: "View"}
                      </button>
                      <button
                        :if={@check}
                        type="button"
                        class="cnc-btn"
                        phx-click="diff_profile"
                        phx-value-profile={p.id}
                      >
                        {if @diffing_profile == p.id, do: "Hide diff", else: "Diff with current"}
                      </button>
                      <button
                        type="button"
                        class="cnc-btn"
                        phx-click="edit_profile"
                        phx-value-profile={p.id}
                      >
                        Edit
                      </button>
                      <button
                        type="button"
                        class="cnc-btn"
                        phx-click="profile_history"
                        phx-value-profile={p.id}
                      >
                        {if @history_for == p.id, do: "Hide history", else: "History"}
                      </button>
                      <button
                        type="button"
                        class="cnc-btn cnc-btn--quiet"
                        phx-click="rename"
                        phx-value-profile={p.id}
                      >
                        Rename
                      </button>
                      <button
                        type="button"
                        class="cnc-btn cnc-btn--quiet"
                        phx-click="delete_profile"
                        phx-value-profile={p.id}
                        data-confirm={"Delete the profile #{p.name}?"}
                      >
                        Delete
                      </button>
                    </div>
                    <div
                      :if={(@check && @diffing_profile == p.id) and @editing_profile != p.id}
                      id={"diff-#{p.id}"}
                      class="cnc-diff"
                    >
                      <%= case Profiles.diff(@check.profile, p) do %>
                        <% [] -> %>
                          <p class="cnc-sub">Same settings as {@check.profile.name}.</p>
                        <% diffs -> %>
                          <p class="cnc-sub">
                            {length(diffs)} {if length(diffs) == 1,
                              do: "setting differs",
                              else: "settings differ"} from {@check.profile.name} (current → {p.name}):
                          </p>
                          <.diff_list diffs={diffs} />
                      <% end %>
                    </div>
                    <div :if={@showing_profile == p.id and @editing_profile != p.id}>
                      <.axes_table
                        values={Configuration.expected(@cnc.db, @controller, p)}
                        id_prefix={"view-#{p.id}"}
                      />
                      <.yaml_view
                        id={"yaml-#{p.id}"}
                        text={Configuration.render(@cnc.db, @controller, p)}
                      />
                    </div>
                    <.revisions
                      :if={@history_for == p.id}
                      id={"history-#{p.id}"}
                      entries={p.history}
                      prefix={"p-#{p.id}"}
                      expanded={@expanded}
                      restore="restore_profile"
                      profile={p.id}
                    />
                  </li>
                </ul>

                <form
                  id="new-profile-form"
                  class="cnc-ctl-form"
                  phx-change="new_change"
                  phx-submit="create"
                >
                  <h3 class="cnc-sub">New profile</h3>
                  <div class="cnc-other-row">
                    <label class="cnc-ctl-field">
                      <span>Name</span>
                      <input
                        name="new[name]"
                        value={@new["name"]}
                        placeholder="Fast accel"
                        autocomplete="off"
                      />
                    </label>
                    <label class="cnc-ctl-field">
                      <span>Starting from</span>
                      <select name="new[from]">
                        <option
                          :for={p <- @profiles}
                          value={p.id}
                          selected={
                            @new["from"] == p.id or (@new["from"] == "" and selected?(@check, p))
                          }
                        >
                          A copy of {p.name}
                        </option>
                        <option value="board" selected={@new["from"] == "board"}>
                          The board's default
                        </option>
                      </select>
                    </label>
                  </div>
                  <div class="cnc-row">
                    <button type="submit" class="cnc-btn">Make profile</button>
                  </div>
                </form>
              </section>

              <section
                :if={@wiring.checked > 0}
                class="cnc-set-group"
                aria-label="Wiring"
                id="config-wiring"
              >
                <h2 class="cnc-h">Wiring</h2>
                <p :if={@wiring.differences == []} class="cnc-sub" id="wiring-ok">
                  Pins and stepping match the {Boards.label(@controller.board)} pin map
                  ({@wiring.checked} settings). Wiring comes from the board, not the profile.
                </p>
                <div :if={@wiring.differences != []} id="wiring-differences">
                  <p class="cnc-note cnc-note--warn">
                    This controller's wiring differs from the {Boards.label(@controller.board)} pin map. Check that the board is right (Controllers page), or that the
                    difference is on purpose.
                  </p>
                  <ul class="cnc-changes">
                    <li :for={w <- @wiring.differences}>
                      <code>{w.path}</code>
                      <span class="cnc-change-vals">
                        board {w.board}, controller <strong>{w.controller}</strong>
                      </span>
                    </li>
                  </ul>
                </div>
              </section>

              <section class="cnc-set-group" aria-label="History" id="config-history">
                <h2 class="cnc-h">History of the controller's config</h2>
                <p :if={@history == []} class="cnc-sub">
                  No changes yet. Every change made from here is kept: why, what changed, and the
                  file it wrote.
                </p>
                <.revisions
                  :if={@history != []}
                  id="controller-history"
                  entries={@history}
                  prefix="c"
                  expanded={@expanded}
                  restore="restore_config"
                  files
                />
              </section>

              <details class="cnc-set-group cnc-advanced" id="advanced" open={@advanced?}>
                <summary class="cnc-h" phx-click="toggle_advanced">
                  Advanced: the controller's config file
                </summary>
                <div class="cnc-row">
                  <button
                    type="button"
                    id="view-file"
                    class="cnc-btn"
                    phx-click={if @viewing, do: "close_view", else: "view"}
                    phx-value-name={active_file(assigns)}
                  >
                    {if @viewing, do: "Hide #{@viewing}", else: "View #{active_file(assigns)}"}
                  </button>
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
                    The escape hatch: a FluidNC config of your own in place of the profile's. It
                    replaces {Configuration.file()} (wiring included) and the controller restarts with
                    it; the page then shows how it differs from the profile. You'll see the
                    changes before anything is written.
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
                    <button
                      type="submit"
                      id="review-override"
                      class="cnc-btn"
                      disabled={
                        (@uploads.config_file.entries == [] and String.trim(@paste) == "") or
                          @machine.moving?
                      }
                    >
                      Review changes
                    </button>
                  </div>
                </form>
              </details>
          <% end %>
          <div
            :if={@pending}
            class="cnc-modal"
            id="approve-modal"
            phx-window-keydown="cancel_pending"
            phx-key="Escape"
          >
            <div
              class="cnc-modal-box"
              role="dialog"
              aria-modal="true"
              aria-labelledby="approve-title"
              phx-click-away="cancel_pending"
            >
              <h2 id="approve-title" class="cnc-modal-title">{@pending.title}</h2>
              <p class="cnc-sub">{@pending.note}</p>
              <p :if={@pending.diffs == []} class="cnc-sub" id="approve-nothing">
                No settings change.
              </p>
              <div :if={@pending.diffs != []} class="cnc-modal-diffs">
                <p class="cnc-sub">{@pending.from_label} → {@pending.to_label}:</p>
                <.diff_list diffs={@pending.diffs} id="approve-diffs" />
              </div>
              <div class="cnc-row">
                <button
                  type="button"
                  id="approve"
                  class="cnc-btn cnc-btn--primary"
                  phx-click="approve"
                  disabled={@machine.moving?}
                >
                  {@pending.approve}
                </button>
                <button type="button" id="cancel-approve" class="cnc-btn" phx-click="cancel_pending">
                  Cancel
                </button>
              </div>
            </div>
          </div>
        </main>
      </div>
    </Layouts.app>
    """
  end

  ## Approved actions

  defp run(socket, {:switch, pid}) do
    %{cnc: cnc, controller: c} = socket.assigns
    name = Enum.find_value(socket.assigns.profiles, &(&1.id == pid && &1.name))

    case Configuration.switch(cnc.machine, cnc.db, c, pid) do
      :ok ->
        {:noreply,
         assign(socket, working: "Writing #{name}: the controller restarts…", error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  defp run(socket, {:apply, changes, other}) do
    {:noreply, socket} = apply_changes(socket, changes)

    if other != nil and socket.assigns.field_errors == %{} and socket.assigns.error == nil,
      do: {:noreply, assign(socket, other: %{"path" => "", "value" => ""})},
      else: {:noreply, socket}
  end

  defp run(socket, {:save_profile, pid, changes}) do
    %{cnc: cnc} = socket.assigns

    case Profiles.edit(cnc.db, pid, changes) do
      {:ok, %{errors: errors}} when errors == %{} ->
        {:noreply, socket |> assign(editing_profile: nil, field_errors: %{}) |> maybe_load()}

      {:ok, %{errors: errors}} ->
        errors = Map.new(errors, fn {path, reason} -> {path, error_text(reason)} end)
        {:noreply, socket |> assign(field_errors: errors) |> maybe_load()}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  defp run(socket, :take_file) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Configuration.take_file(cnc.machine, cnc.db, c) do
      :ok ->
        {:noreply, assign(socket, working: "Writing it: the controller restarts…", error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  defp run(socket, :keep_drift) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Configuration.keep_drift(cnc.machine, cnc.db, c) do
      :ok -> {:noreply, socket |> assign(error: nil) |> maybe_load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  defp run(socket, {:override, text, reason}) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Configuration.replace_file(cnc.machine, cnc.db, c, text, reason) do
      :ok ->
        {:noreply,
         assign(socket,
           working: "Writing your config: the controller restarts…",
           paste: "",
           viewing: nil,
           error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  defp run(socket, {:restore_config, i}) do
    %{cnc: cnc, controller: c, history: history} = socket.assigns

    with %{} = rev <- Enum.at(history, i) || {:error, :not_found},
         {:ok, file} <- History.restore(cnc.machine, cnc.db, c.id, rev),
         :ok <-
           if(file == Configuration.file(), do: FluidNC.activate(cnc.machine, file), else: :ok) do
      {:noreply,
       assign(socket, working: "Restoring v#{rev.version}: the controller restarts…", error: nil)}
    else
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  defp run(socket, {:restore_profile, pid, i}) do
    %{cnc: cnc, controller: c, check: check} = socket.assigns

    case Configuration.restore_profile(cnc.machine, cnc.db, c, pid, i) do
      :ok ->
        if check && check.profile.id == pid,
          do:
            {:noreply,
             assign(socket, working: "Writing it: the controller restarts…", error: nil)},
          else: {:noreply, socket |> assign(error: nil) |> maybe_load()}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  defp run(socket, {:restore_layer, layer, i}) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Configuration.restore_part(cnc.machine, cnc.db, c, layer, i) do
      :ok ->
        {:noreply, assign(socket, working: "Writing it: the controller restarts…", error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  defp run(socket, :put_back) do
    %{cnc: cnc, controller: c} = socket.assigns
    Configuration.put_back(cnc.machine, cnc.db, c)
    {:noreply, socket |> assign(error: nil) |> maybe_load()}
  end

  # Changes to the profile in use, shown first.
  defp ask_apply(socket, [], _other),
    do: {:noreply, assign(socket, field_errors: %{}, error: nil)}

  defp ask_apply(socket, changes, other) do
    %{check: check, settings: running, current: current} = socket.assigns
    name = check.profile.name
    layers = changes |> Enum.map(fn {p, _} -> Build.layer(p) end) |> Enum.uniq()
    wiring? = :wiring in layers

    where =
      Enum.map_join(layers, ", ", fn
        :profile -> "profile #{name}"
        :build -> "the machine's build"
        :wiring -> "this controller's wiring"
        :label -> "the file's names"
      end)

    ask(socket,
      title: "Apply",
      note:
        if(wiring?,
          do:
            "Kept in #{where}, and written to the controller, which restarts: FluidNC only changes wiring at startup.",
          else: "Set on the controller straight away, and kept in #{where} (and its config file)."
        ),
      approve: if(wiring?, do: "Apply and restart", else: "Apply"),
      diffs:
        for(
          {path, v} <- changes,
          do: %{path: path, from: current[path] || running[path], to: v}
        ),
      from_label: "now",
      to_label: "new",
      action: {:apply, changes, other}
    )
  end

  defp ask(socket, opts), do: {:noreply, assign(socket, pending: Map.new(opts))}

  defp apply_changes(socket, []), do: {:noreply, assign(socket, field_errors: %{}, error: nil)}

  defp apply_changes(socket, changes) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Configuration.set(cnc.machine, cnc.db, c, changes) do
      {:ok, %{restart?: true}} ->
        {:noreply,
         assign(socket,
           working: "Wiring changed: the controller restarts…",
           editing_current?: false,
           error: nil
         )}

      {:ok, %{errors: errors}} ->
        errors = Map.new(errors, fn {path, reason} -> {path, error_text(reason)} end)

        {:noreply,
         socket
         |> assign(field_errors: errors, error: nil, editing_current?: errors != %{})
         |> maybe_load()}

      {:error, reason} ->
        {:noreply, socket |> assign(error: error_text(reason)) |> maybe_load()}
    end
  end

  attr :values, :map, required: true
  attr :id_prefix, :string, required: true
  attr :editable, :boolean, default: false
  attr :only_profile, :boolean, default: false
  attr :errors, :map, default: %{}

  # The usual per-axis settings, read-only or as inputs named set[path].
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
            class={[
              (not @editable or (@only_profile and not Profiles.editable?("axes/#{a}/#{field}"))) &&
                "cnc-axes-value"
            ]}
          >
            <%= if @editable and not (@only_profile and not Profiles.editable?("axes/#{a}/#{field}")) do %>
              <input
                name={"set[axes/#{a}/#{field}]"}
                id={"#{@id_prefix}-#{a}-#{field}"}
                value={shown(@values["axes/#{a}/#{field}"])}
                inputmode="decimal"
                autocomplete="off"
                aria-label={"#{String.upcase(a)} #{label}"}
                class={[@errors["axes/#{a}/#{field}"] && "is-error"]}
                title={@errors["axes/#{a}/#{field}"]}
              />
            <% else %>
              <span id={"#{@id_prefix}-#{a}-#{field}"}>{shown(@values["axes/#{a}/#{field}"])}</span>
            <% end %>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :id, :string, required: true
  attr :entries, :list, required: true
  attr :prefix, :string, required: true
  attr :expanded, :any, required: true
  attr :restore, :string, required: true
  attr :profile, :string, default: nil
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
          <p :if={e.diff == []} class="cnc-sub">No settings changed.</p>
          <div class="cnc-row">
            <button
              :if={i > 0 and (not @files or is_binary(e.text))}
              type="button"
              class="cnc-btn"
              phx-click={@restore}
              phx-value-i={i}
              phx-value-profile={@profile}
            >
              Restore v{e.version}
            </button>
            <button
              :if={@files and is_binary(e.text)}
              type="button"
              class="cnc-btn cnc-btn--quiet"
              phx-click="toggle_rev"
              phx-value-key={"#{@prefix}-#{e.version}-file"}
            >
              {if MapSet.member?(@expanded, "#{@prefix}-#{e.version}-file"),
                do: "Hide file",
                else: "View file"}
            </button>
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
          {settings_count(length(@added))} added (FluidNC's defaults were in use for them)
        </summary>
        <ul class="cnc-changes">
          <.diff_row :for={d <- @added} d={d} list={@id} />
        </ul>
      </details>
      <details :if={@removed != []} class="cnc-diff-more">
        <summary>
          {settings_count(length(@removed))} removed (left to FluidNC's defaults)
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

  defp settings_count(1), do: "1 setting"
  defp settings_count(n), do: "#{n} settings"

  defp changes_label([]), do: "no settings changed"

  defp changes_label(diff) do
    changed = Enum.count(diff, &(&1.from != nil and &1.to != nil))
    other = length(diff) - changed

    case {changed, other} do
      {c, 0} -> "#{settings_count(c)} changed"
      {0, o} -> "#{settings_count(o)} added or removed"
      {c, o} -> "#{settings_count(c)} changed, #{o} added or removed"
    end
  end

  attr :profile, :map, required: true

  defp rename_form(assigns) do
    ~H"""
    <form id={"rename-#{@profile.id}"} class="cnc-rename" phx-submit="save_name">
      <input type="hidden" name="profile" value={@profile.id} />
      <input name="name" value={@profile.name} autocomplete="off" aria-label="Profile name" />
      <button type="submit" class="cnc-btn">Save</button>
      <button type="button" class="cnc-btn cnc-btn--quiet" phx-click="cancel_rename">
        Cancel
      </button>
    </form>
    """
  end

  # The check's differences as a diff: from what the configuration says to
  # what the file holds.
  defp check_diffs(check),
    do: for(d <- check.differences, do: %{path: d.path, from: d.profile, to: d.controller})

  defp others(profiles, %{profile: %{id: id}}), do: Enum.reject(profiles, &(&1.id == id))
  defp others(profiles, _), do: profiles

  defp machine(socket), do: socket.assigns.cnc.machine

  # This controller in use and the machine ready for commands.
  defp ready?(assigns),
    do:
      assigns.active? and assigns.machine.connected? and assigns.machine.state in [:alarm, :idle]

  defp refresh_active(socket) do
    active = Controllers.active(socket.assigns.cnc.controllers)
    assign(socket, active?: active != nil and active.id == socket.assigns.controller.id)
  end

  defp maybe_load(socket) do
    %{cnc: cnc, controller: c} = socket.assigns

    if connected?(socket) and ready?(socket.assigns) do
      with :ok <- Configuration.ensure(cnc.machine, cnc.db, c),
           {:ok, check} <- Configuration.check(cnc.machine, cnc.db, c),
           {:ok, %{files: files}} <- FluidNC.files(cnc.machine),
           {:ok, running} <- FluidNC.running(cnc.machine),
           {:ok, drift} <- Configuration.drift(cnc.machine, cnc.db, c) do
        settings = Values.parse(running)

        assign(socket,
          profiles: Profiles.list(cnc.db),
          build_history: Build.history(cnc.db),
          wiring_history: Wiring.history(cnc.db, c.id),
          check: check,
          files: files,
          settings: Map.new(settings),
          paths: for({p, _} <- settings, Build.layer(p) != :label, do: p),
          current: Configuration.expected(cnc.db, c, check.profile),
          drift: drift,
          wiring: Configuration.wiring_check(c.board, settings),
          history: History.list(cnc.db, c.id)
        )
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

  # Axes that have the usual settings, in the config's order.
  # Axes with any of the usual settings, and the rows any of them has (a
  # controller shows only what its config holds: the fake sim has no steps).
  defp axes(settings) do
    for a <- ~w(x y z a b c),
        Enum.any?(@axis_fields, fn {f, _} -> Map.has_key?(settings, "axes/#{a}/#{f}") end),
        do: a
  end

  defp axis_rows(settings) do
    for {f, _} = row <- @axis_fields,
        Enum.any?(axes(settings), &Map.has_key?(settings, "axes/#{&1}/#{f}")),
        do: row
  end

  defp clean_path(path),
    do: (path || "") |> String.trim() |> String.trim_leading("$/") |> String.downcase()

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

  defp error_text(:name_required), do: "Give the profile a name."
  defp error_text(:exists), do: "There's already one with that name."
  defp error_text(:in_use), do: "That's the selected profile: switch to another first."
  defp error_text(:no_profile), do: "No profile is selected."

  defp error_text(:not_profile_setting),
    do:
      "That's part of the machine's build or the wiring, the same for every profile: change it in the current configuration."

  defp error_text(:not_editable), do: "That's a name in the file, not a setting."
  defp error_text(:nothing_to_use), do: "Choose a file, or paste a config."
  defp error_text(:no_file), do: "That version has no file (a live change)."
  defp error_text(:not_yaml), do: "Choose a FluidNC config file (.yaml or .yml)."
  defp error_text(:not_a_config), do: "That file doesn't look like a FluidNC config."
  defp error_text(:selected), do: "That's the current profile: edit it above."
  defp error_text(:not_a_number), do: "That needs a number."

  defp error_text(:override),
    do: "The controller loaded a file directly: switch to a profile to change settings."

  defp error_text({:not_written, reason}),
    do: "Applied, but writing the profile's file failed: #{error_text(reason)}"

  defp error_text(:unknown_setting), do: "The controller has no such setting."
  defp error_text(:invalid_setting), do: "A setting is a path like axes/x/max_rate_mm_per_min."
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

  defp state_word(state) do
    %{
      disconnected: "Not connected",
      connecting: "Connecting",
      alarm: "Locked",
      idle: "Ready",
      jogging: "Jogging",
      uploading: "Uploading",
      homing: "Homing",
      busy: "Busy"
    }[state]
  end
end
