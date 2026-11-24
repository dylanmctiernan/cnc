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
  alias CNC.Controllers.{Config, Profiles}

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
         |> assign(viewing: nil, text: nil, showing: nil, renaming: nil, error: nil)
         |> assign(working: nil, field_errors: %{}, other: %{"path" => "", "value" => ""})
         |> assign(new: %{"name" => "", "from" => ""}, advanced?: false)
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

  def handle_event("switch", %{"profile" => pid}, socket) do
    %{cnc: cnc, controller: c} = socket.assigns
    name = Enum.find_value(socket.assigns.profiles, &(&1.id == pid && &1.name))

    case Profiles.switch(cnc.machine, cnc.db, c, pid) do
      :ok ->
        {:noreply,
         assign(socket, working: "Switching to #{name}: the controller restarts…", error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
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

    case Profiles.create(cnc.db, c.id, name, c.board, from) do
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
    %{cnc: cnc, controller: c} = socket.assigns

    case Profiles.rename(cnc.db, c.id, pid, name) do
      :ok -> {:noreply, socket |> assign(renaming: nil, error: nil) |> maybe_load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("delete_profile", %{"profile" => pid}, socket) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Profiles.delete(cnc.db, c.id, pid) do
      :ok -> {:noreply, socket |> assign(error: nil) |> maybe_load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  ## Settings of the profile in use

  # The axis table: every value that differs from what's running is set.
  def handle_event("apply_axes", %{"set" => values}, socket) do
    %{settings: settings} = socket.assigns

    changes =
      for {path, value} <- values,
          String.trim(value) != "",
          not same_value?(settings[path], value),
          do: {path, value}

    apply_changes(socket, changes)
  end

  def handle_event("other_change", %{"other" => other}, socket),
    do: {:noreply, assign(socket, other: other)}

  def handle_event(
        "apply_other",
        %{"other" => %{"path" => path, "value" => value} = other},
        socket
      ) do
    {:noreply, socket} = apply_changes(socket, [{path, value}])

    if socket.assigns.field_errors == %{} and socket.assigns.error == nil,
      do: {:noreply, assign(socket, other: %{"path" => "", "value" => ""})},
      else: {:noreply, assign(socket, other: other)}
  end

  def handle_event("keep_drift", _, socket) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Profiles.keep_drift(cnc.machine, cnc.db, c) do
      :ok -> {:noreply, socket |> assign(error: nil) |> maybe_load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("take_file", _, socket) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Profiles.take_file(cnc.machine, cnc.db, c) do
      :ok -> {:noreply, socket |> assign(error: nil) |> maybe_load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("put_back", _, socket) do
    %{cnc: cnc, controller: c} = socket.assigns
    Profiles.put_back(cnc.machine, cnc.db, c.id)
    {:noreply, socket |> assign(error: nil) |> maybe_load()}
  end

  ## Files (advanced)

  # Kept open across updates (a <details> opened in the browser alone would
  # close on the next render).
  def handle_event("toggle_advanced", _, socket),
    do: {:noreply, update(socket, :advanced?, &(not &1))}

  def handle_event("view", %{"name" => name}, socket) do
    case Config.show(machine(socket), name) do
      {:ok, text} -> {:noreply, assign(socket, viewing: name, text: text, error: nil)}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("close_view", _, socket),
    do: {:noreply, assign(socket, viewing: nil, text: nil)}

  def handle_event("use_file", %{"name" => name}, socket) do
    case Profiles.use_file(machine(socket), name) do
      :ok ->
        {:noreply,
         assign(socket, working: "Loading #{name}: the controller restarts…", error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("restart", _, socket) do
    case Config.activate(machine(socket), active_file(socket.assigns)) do
      :ok -> {:noreply, assign(socket, working: "Restarting…", error: nil)}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("delete", %{"name" => name}, socket) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Config.delete(cnc.machine, name, {cnc.db, c.id}) do
      :ok ->
        socket = if socket.assigns.viewing == name, do: assign(socket, viewing: nil), else: socket
        {:noreply, socket |> assign(error: nil) |> maybe_load()}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("show_version", %{"i" => i}, socket) do
    i = String.to_integer(i)
    {:noreply, assign(socket, showing: if(socket.assigns.showing == i, do: nil, else: i))}
  end

  def handle_event("restore", %{"i" => i}, socket) do
    %{cnc: cnc, controller: c, history: history} = socket.assigns
    version = Enum.at(history, String.to_integer(i))

    case version && Config.restore(cnc.machine, cnc.db, c.id, version) do
      {:ok, file} ->
        note =
          if file == active_file(socket.assigns),
            do: "Restored #{file}. Restart the controller to load it.",
            else: "Restored #{file}."

        {:noreply,
         socket |> assign(error: nil, showing: nil) |> put_flash(:info, note) |> maybe_load()}

      nil ->
        {:noreply, assign(socket, error: "That version isn't in the history any more.")}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

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
              <section :if={@check} class="cnc-set-group" id="in-use" aria-label="In use">
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
                <div :if={not @check.matches?} id="check-differences">
                  <ul :if={@check.differences != []} class="cnc-changes">
                    <li
                      :for={d <- Enum.take(@check.differences, 12)}
                      id={"diff-#{dom_id(d.path)}"}
                    >
                      <code>{d.path}</code>
                      <span class="cnc-change-vals">
                        profile {shown(d.profile) || "none"}, controller
                        <strong>{shown(d.controller) || "none"}</strong>
                      </span>
                    </li>
                  </ul>
                  <p :if={length(@check.differences) > 12} class="cnc-sub">
                    and {length(@check.differences) - 12} more.
                  </p>
                  <div class="cnc-row">
                    <button
                      type="button"
                      id="write-profile"
                      class="cnc-btn cnc-btn--primary"
                      phx-click="switch"
                      phx-value-profile={@check.profile.id}
                      disabled={@machine.moving?}
                      data-confirm={"Write #{@check.profile.name} to the controller and restart it? What its file holds now goes into the history."}
                    >
                      Write {@check.profile.name} and restart
                    </button>
                    <button
                      :if={not @check.override?}
                      type="button"
                      id="take-file"
                      class="cnc-btn"
                      phx-click="take_file"
                      data-confirm={"Replace #{@check.profile.name}'s values with the controller's file?"}
                    >
                      Keep the controller's values in {@check.profile.name}
                    </button>
                  </div>
                </div>
              </section>

              <section class="cnc-set-group" aria-label="Profiles">
                <h2 class="cnc-h">Profiles</h2>
                <ul class="cnc-ctls" id="profiles">
                  <li
                    :for={p <- @profiles}
                    id={"profile-#{p.id}"}
                    class={["cnc-ctl-card", selected?(@check, p) && "is-active"]}
                  >
                    <div class="cnc-ctl-card-head">
                      <h3 :if={@renaming != p.id} class="cnc-ctl-name">{p.name}</h3>
                      <form
                        :if={@renaming == p.id}
                        id={"rename-#{p.id}"}
                        class="cnc-rename"
                        phx-submit="save_name"
                      >
                        <input type="hidden" name="profile" value={p.id} />
                        <input
                          name="name"
                          value={p.name}
                          autocomplete="off"
                          aria-label="Profile name"
                        />
                        <button type="submit" class="cnc-btn">Save</button>
                        <button
                          type="button"
                          class="cnc-btn cnc-btn--quiet"
                          phx-click="cancel_rename"
                        >
                          Cancel
                        </button>
                      </form>
                      <span :if={selected?(@check, p)} class="cnc-ctl-tag">Selected</span>
                    </div>
                    <div :if={@renaming != p.id} class="cnc-row">
                      <button
                        :if={not selected?(@check, p)}
                        type="button"
                        class="cnc-btn cnc-btn--primary"
                        phx-click="switch"
                        phx-value-profile={p.id}
                        disabled={@machine.moving?}
                        data-confirm={"Switch to #{p.name}? The controller restarts with it and comes back locked."}
                      >
                        Switch to this
                      </button>
                      <button
                        type="button"
                        class="cnc-btn"
                        phx-click="rename"
                        phx-value-profile={p.id}
                      >
                        Rename
                      </button>
                      <button
                        :if={not selected?(@check, p)}
                        type="button"
                        class="cnc-btn cnc-btn--quiet"
                        phx-click="delete_profile"
                        phx-value-profile={p.id}
                        data-confirm={"Delete the profile #{p.name}? Its file stays on the controller."}
                      >
                        Delete
                      </button>
                    </div>
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
                :if={@check && not @check.override?}
                class="cnc-set-group"
                aria-label="Settings"
              >
                <h2 class="cnc-h">Settings of {@check.profile.name}</h2>
                <form
                  :if={axes(@settings) != []}
                  id="axes-form"
                  class="cnc-axes-form"
                  phx-submit="apply_axes"
                >
                  <table class="cnc-axes">
                    <thead>
                      <tr>
                        <th></th>
                        <th :for={a <- axes(@settings)} scope="col">{String.upcase(a)}</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={{field, label} <- axis_fields()}>
                        <th scope="row">{label}</th>
                        <td :for={a <- axes(@settings)}>
                          <input
                            name={"set[axes/#{a}/#{field}]"}
                            id={"set-#{a}-#{field}"}
                            value={shown(@settings["axes/#{a}/#{field}"])}
                            inputmode="decimal"
                            autocomplete="off"
                            aria-label={"#{String.upcase(a)} #{label}"}
                            class={[@field_errors["axes/#{a}/#{field}"] && "is-error"]}
                            title={@field_errors["axes/#{a}/#{field}"]}
                          />
                        </td>
                      </tr>
                    </tbody>
                  </table>
                  <p :for={{path, msg} <- @field_errors} class="cnc-set-error">{path}: {msg}</p>
                  <div class="cnc-row">
                    <button type="submit" class="cnc-btn cnc-btn--primary" id="apply-axes">
                      Apply
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
              </section>

              <section
                :if={@drift != []}
                class="cnc-set-group"
                aria-label="Differences"
                id="config-drift"
              >
                <h2 class="cnc-h">Running values that differ from {@check.profile.name}</h2>
                <p class="cnc-sub">
                  It's running values the profile doesn't have (changed in the console, say).
                  Keep them in the profile, or put the profile's back.
                </p>
                <ul class="cnc-changes">
                  <li :for={d <- @drift} id={"drift-#{dom_id(d.path)}"}>
                    <code>{d.path}</code>
                    <span class="cnc-change-vals">
                      profile {shown(d.profile)}, controller <strong>{shown(d.controller)}</strong>
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
                    Keep in profile
                  </button>
                  <button type="button" id="put-back" class="cnc-btn" phx-click="put_back">
                    Put back
                  </button>
                </div>
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

              <details class="cnc-set-group cnc-advanced" id="advanced" open={@advanced?}>
                <summary class="cnc-h" phx-click="toggle_advanced">
                  Advanced: the files on the controller
                </summary>
                <p class="cnc-sub">
                  The app keeps one file here, config.yaml, written from the selected profile;
                  its earlier versions are kept in the app. Loading another file directly
                  overrides the profiles until you switch to one.
                </p>
                <ul class="cnc-ctls" id="config-files">
                  <li
                    :for={f <- @files}
                    id={"config-file-#{dom_id(f.name)}"}
                    class={["cnc-ctl-card", f.name == active_file(assigns) && "is-active"]}
                  >
                    <div class="cnc-ctl-card-head">
                      <h3 class="cnc-ctl-name">{f.name}</h3>
                      <span :if={f.name == active_file(assigns)} class="cnc-ctl-tag">Loaded</span>
                      <span :if={f.name == Profiles.file()} class="cnc-dim">the app's file</span>
                      <span class="cnc-ctl-size">{size(f.size)}</span>
                    </div>
                    <div class="cnc-row">
                      <button
                        type="button"
                        class="cnc-btn"
                        phx-click={if @viewing == f.name, do: "close_view", else: "view"}
                        phx-value-name={f.name}
                      >
                        {if @viewing == f.name, do: "Hide", else: "View"}
                      </button>
                      <button
                        :if={f.name == active_file(assigns)}
                        type="button"
                        class="cnc-btn"
                        id="restart-controller"
                        phx-click="restart"
                        disabled={@machine.moving?}
                        data-confirm="Restart the controller? It reloads this file and comes back locked."
                      >
                        Restart to reload
                      </button>
                      <button
                        :if={f.name != active_file(assigns)}
                        type="button"
                        class="cnc-btn"
                        phx-click="use_file"
                        phx-value-name={f.name}
                        disabled={@machine.moving?}
                        data-confirm={"Load #{f.name} directly? The controller restarts with it, outside the profiles."}
                      >
                        Use this file directly
                      </button>
                      <button
                        :if={f.name != active_file(assigns)}
                        type="button"
                        class="cnc-btn cnc-btn--quiet"
                        phx-click="delete"
                        phx-value-name={f.name}
                        data-confirm={"Delete #{f.name} from the controller?"}
                      >
                        Delete
                      </button>
                    </div>
                    <pre :if={@viewing == f.name} class="cnc-config-text" id="config-text">{@text}</pre>
                  </li>
                </ul>

                <div :if={@history != []} id="config-history-group">
                  <h3 class="cnc-sub">Earlier versions</h3>
                  <ul class="cnc-ctls" id="config-history">
                    <li
                      :for={{v, i} <- Enum.with_index(@history)}
                      id={"version-#{i}"}
                      class="cnc-ctl-card"
                    >
                      <div class="cnc-ctl-card-head">
                        <h3 class="cnc-ctl-name">{v.file}</h3>
                        <span class="cnc-ctl-size">
                          {Calendar.strftime(v.at, "%Y-%m-%d %H:%M")} UTC, {v.why}
                        </span>
                      </div>
                      <div class="cnc-row">
                        <button
                          type="button"
                          class="cnc-btn"
                          phx-click="show_version"
                          phx-value-i={i}
                        >
                          {if @showing == i, do: "Hide", else: "View"}
                        </button>
                        <button
                          type="button"
                          class="cnc-btn"
                          phx-click="restore"
                          phx-value-i={i}
                          data-confirm={"Write this version back into #{v.file}? What it holds now goes into the history."}
                        >
                          Restore
                        </button>
                      </div>
                      <pre :if={@showing == i} class="cnc-config-text">{v.text}</pre>
                    </li>
                  </ul>
                </div>
              </details>
          <% end %>
        </main>
      </div>
    </Layouts.app>
    """
  end

  defp apply_changes(socket, []), do: {:noreply, assign(socket, field_errors: %{}, error: nil)}

  defp apply_changes(socket, changes) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Profiles.set(cnc.machine, cnc.db, c, changes) do
      {:ok, %{errors: errors}} ->
        errors = Map.new(errors, fn {path, reason} -> {path, error_text(reason)} end)
        {:noreply, socket |> assign(field_errors: errors, error: nil) |> maybe_load()}

      {:error, reason} ->
        {:noreply, socket |> assign(error: error_text(reason)) |> maybe_load()}
    end
  end

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
      with :ok <- Profiles.ensure(cnc.machine, cnc.db, c.id),
           {:ok, check} <- Profiles.check(cnc.machine, cnc.db, c),
           {:ok, %{files: files}} <- Config.files(cnc.machine),
           {:ok, running} <- Config.running(cnc.machine),
           {:ok, drift} <- Profiles.drift(cnc.machine, cnc.db, c.id) do
        settings = Config.parse(running)

        assign(socket,
          profiles: Profiles.list(cnc.db, c.id),
          check: check,
          files: files,
          settings: Map.new(settings),
          paths: for({p, _} <- settings, Profiles.editable?(p), do: p),
          drift: drift,
          wiring: Config.wiring_check(c.board, settings),
          history: Config.history(cnc.db, c.id)
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

  defp axis_fields, do: @axis_fields

  # Axes that have the usual settings, in the config's order.
  defp axes(settings) do
    for a <- ~w(x y z a b c), Map.has_key?(settings, "axes/#{a}/steps_per_mm"), do: a
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
  defp same_value?(a, b), do: Config.same?(a, String.trim(b))

  defp waiting_text(:disconnected), do: "Not connected yet: waiting for the controller."
  defp waiting_text(:connecting), do: "Connecting…"
  defp waiting_text(:uploading), do: "Sending a file to the controller…"
  defp waiting_text(_), do: "The machine is moving: the configuration is available once it stops."

  defp dom_id(name), do: String.replace(name, ~r/[^A-Za-z0-9_-]/, "-")

  defp size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"

  defp error_text(:name_required), do: "Give the profile a name."
  defp error_text(:exists), do: "There's already one with that name."
  defp error_text(:in_use), do: "That's the selected profile: switch to another first."
  defp error_text(:no_profile), do: "No profile is selected."

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
