defmodule CNCWeb.ConfigLive do
  @moduledoc """
  One controller's configuration (`/controllers/:id/configuration`):
  changing settings live (per axis, or any setting by path), the changes not
  saved yet (undo, or save them into the file it loads), the config files on
  it (view, save what's running as a new file, switch, which restarts it,
  delete) and earlier versions. Needs that controller connected; otherwise
  it offers to connect it.
  """
  use CNCWeb, :live_view

  on_mount CNCWeb.Pin

  alias CNC.{Controllers, Machine}
  alias CNC.Controllers.Config

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
         |> assign(files: nil, active_file: nil, viewing: nil, text: nil, error: nil)
         |> assign(save_name: "", working: nil)
         |> assign(settings: %{}, paths: [], changes: [], history: [], showing: nil)
         |> assign(wiring: %{checked: 0, differences: []})
         |> assign(other: %{"path" => "", "value" => ""}, field_errors: %{})
         |> refresh_active()
         |> maybe_load()}
    end
  end

  @impl true
  def handle_info({:machine, machine}, socket) do
    was_ready? = ready?(socket.assigns)
    socket = assign(socket, machine: machine)

    # Came back (connected, or after a restart): read the files again.
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

  def handle_event("view", %{"name" => name}, socket) do
    case Config.show(machine(socket), name) do
      {:ok, text} -> {:noreply, assign(socket, viewing: name, text: text, error: nil)}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("close_view", _, socket),
    do: {:noreply, assign(socket, viewing: nil, text: nil)}

  def handle_event("save_change", %{"save" => %{"name" => name}}, socket),
    do: {:noreply, assign(socket, save_name: name)}

  def handle_event("save_as", %{"save" => %{"name" => name}}, socket) do
    with {:ok, name} <- Config.valid_name(name),
         false <- Enum.any?(socket.assigns.files || [], &(&1.name == name)) && {:error, :exists},
         {:ok, name} <- Config.save_running_as(machine(socket), name) do
      {:noreply,
       socket
       |> assign(save_name: "", error: nil)
       |> put_flash(:info, "Saved the running config as #{name}.")
       |> maybe_load()}
    else
      {:error, reason} -> {:noreply, assign(socket, save_name: name, error: error_text(reason))}
    end
  end

  def handle_event("activate", %{"name" => name}, socket) do
    case Config.activate(machine(socket), name) do
      :ok ->
        {:noreply,
         assign(socket, working: "Restarting with #{name}…", viewing: nil, text: nil, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  # The axis table: every value that differs from what's running is set.
  def handle_event("apply_axes", %{"set" => values}, socket) do
    %{settings: settings} = socket.assigns

    errors =
      for {path, value} <- values,
          String.trim(value) != "",
          not same_value?(settings[path], value),
          {:error, reason} <- [change(socket, path, value)],
          into: %{},
          do: {path, error_text(reason)}

    {:noreply, socket |> assign(field_errors: errors, error: nil) |> maybe_load()}
  end

  def handle_event("other_change", %{"other" => other}, socket),
    do: {:noreply, assign(socket, other: other)}

  def handle_event(
        "apply_other",
        %{"other" => %{"path" => path, "value" => value} = other},
        socket
      ) do
    path = path |> String.trim() |> String.trim_leading("$/") |> String.trim("/")

    case change(socket, path, value) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(other: %{"path" => "", "value" => ""}, error: nil) |> maybe_load()}

      {:error, reason} ->
        {:noreply, assign(socket, other: other, error: error_text(reason))}
    end
  end

  def handle_event("undo", %{"path" => path}, socket) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Config.undo(cnc.machine, cnc.db, c.id, path) do
      :ok -> {:noreply, socket |> assign(error: nil) |> maybe_load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason)) |> maybe_load()}
    end
  end

  def handle_event("save_changes", _, socket) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Config.save(cnc.machine, cnc.db, c.id) do
      {:ok, file} ->
        {:noreply,
         socket
         |> assign(error: nil)
         |> put_flash(:info, "Saved into #{file}. The previous version is in the history.")
         |> maybe_load()}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("show_version", %{"i" => i}, socket) do
    i = String.to_integer(i)
    {:noreply, assign(socket, showing: if(socket.assigns.showing == i, do: nil, else: i))}
  end

  def handle_event("delete", %{"name" => name}, socket) do
    %{cnc: cnc, controller: c} = socket.assigns

    case Config.delete(machine(socket), name, {cnc.db, c.id}) do
      :ok ->
        socket = if socket.assigns.viewing == name, do: assign(socket, viewing: nil), else: socket
        {:noreply, socket |> assign(error: nil) |> maybe_load()}

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
            The configuration lives on the controller as files, and it loads one when it
            starts. Change settings here to try them on the machine right away; save them
            into the file to keep them, or restart to drop them. Keep variations as separate
            files and switch between them (the controller restarts and comes back locked).
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
              <p class="cnc-note" id="config-waiting">
                {waiting_text(@machine.state)}
              </p>
            <% true -> %>
              <section class="cnc-set-group" aria-label="Settings">
                <h2 class="cnc-h">Settings</h2>
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
                            class={[
                              unsaved?(@changes, "axes/#{a}/#{field}") && "is-changed",
                              @field_errors["axes/#{a}/#{field}"] && "is-error"
                            ]}
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
                          (now {@settings[clean_path(@other["path"])]})
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
                :if={@wiring.checked > 0}
                class="cnc-set-group"
                aria-label="Wiring"
                id="config-wiring"
              >
                <h2 class="cnc-h">Wiring</h2>
                <p :if={@wiring.differences == []} class="cnc-sub" id="wiring-ok">
                  Pins and stepping match the {CNC.Boards.label(@controller.board)} pin map
                  ({@wiring.checked} settings). Wiring is set by the board: it changes in a
                  config file, not here.
                </p>
                <div :if={@wiring.differences != []} id="wiring-differences">
                  <p class="cnc-note cnc-note--warn">
                    This controller's wiring differs from the {CNC.Boards.label(@controller.board)} pin map. Check that the board is right (Controllers page), or that the
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

              <section
                :if={@changes != []}
                class="cnc-set-group"
                aria-label="Changes not saved"
                id="config-changes"
              >
                <h2 class="cnc-h">Not saved yet</h2>
                <p class="cnc-sub">
                  The controller is using these now. Save them into {@active_file} to keep
                  them; restarting the controller drops them.
                </p>
                <ul class="cnc-changes">
                  <li :for={c <- @changes} id={"change-#{dom_id(c.path)}"}>
                    <code>{c.path}</code>
                    <span class="cnc-change-vals">
                      {shown(c.from)} → <strong>{shown(c.to)}</strong>
                    </span>
                    <button
                      type="button"
                      class="cnc-btn cnc-btn--quiet"
                      phx-click="undo"
                      phx-value-path={c.path}
                    >
                      Undo
                    </button>
                  </li>
                </ul>
                <div class="cnc-row">
                  <button
                    type="button"
                    id="save-changes"
                    class="cnc-btn cnc-btn--primary"
                    phx-click="save_changes"
                    data-confirm={"Save into #{@active_file}? Its current version goes into the history."}
                  >
                    Save into {@active_file}
                  </button>
                </div>
              </section>

              <section class="cnc-set-group" aria-label="Config files">
                <h2 class="cnc-h">Config files</h2>
                <p :if={@files == []} class="cnc-note">No config files found on the controller.</p>
                <ul class="cnc-ctls" id="config-files">
                  <li
                    :for={f <- @files || []}
                    id={"config-file-#{dom_id(f.name)}"}
                    class={["cnc-ctl-card", f.name == @active_file && "is-active"]}
                  >
                    <div class="cnc-ctl-card-head">
                      <h3 class="cnc-ctl-name">{f.name}</h3>
                      <span :if={f.name == @active_file} class="cnc-ctl-tag">Loaded at start</span>
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
                        :if={f.name != @active_file}
                        type="button"
                        class="cnc-btn cnc-btn--primary"
                        phx-click="activate"
                        phx-value-name={f.name}
                        disabled={@machine.moving?}
                        data-confirm={"Switch to #{f.name}? The controller restarts and comes back locked."}
                      >
                        Use this config
                      </button>
                      <button
                        :if={f.name != @active_file}
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
              </section>

              <section class="cnc-set-group" aria-label="Save the running config">
                <h2 class="cnc-h">Save the running config as a new file</h2>
                <p class="cnc-sub">
                  A copy of what the controller is running now, to try changes on without
                  touching {@active_file || "the current file"}.
                </p>
                <form
                  id="save-as-form"
                  class="cnc-ctl-form"
                  phx-change="save_change"
                  phx-submit="save_as"
                >
                  <label class="cnc-ctl-field">
                    <span>File name</span>
                    <input
                      name="save[name]"
                      value={@save_name}
                      placeholder="fast-accel.yaml"
                      autocomplete="off"
                    />
                  </label>
                  <div class="cnc-row">
                    <button type="submit" class="cnc-btn cnc-btn--primary">Save as new file</button>
                  </div>
                </form>
              </section>

              <section :if={@history != []} class="cnc-set-group" aria-label="Earlier versions">
                <h2 class="cnc-h">Earlier versions</h2>
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
                      <button type="button" class="cnc-btn" phx-click="show_version" phx-value-i={i}>
                        {if @showing == i, do: "Hide", else: "View"}
                      </button>
                    </div>
                    <pre :if={@showing == i} class="cnc-config-text">{v.text}</pre>
                  </li>
                </ul>
              </section>
          <% end %>
        </main>
      </div>
    </Layouts.app>
    """
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
      with {:ok, %{files: files, active: active}} <- Config.files(cnc.machine),
           {:ok, running} <- Config.running(cnc.machine) do
        settings = Config.parse(running)

        assign(socket,
          files: files,
          active_file: active,
          settings: Map.new(settings),
          paths: for({p, _} <- settings, not CNC.Boards.wiring?(p), do: p),
          wiring: Config.wiring_check(c.board, settings),
          changes: unsaved(cnc, c),
          history: Config.history(cnc.db, c.id)
        )
      else
        {:error, reason} -> assign(socket, error: error_text(reason))
      end
    else
      assign(socket, history: Config.history(cnc.db, c.id))
    end
  end

  defp unsaved(cnc, c) do
    case Config.changes(cnc.machine, cnc.db, c.id) do
      {:ok, list} -> list
      {:error, _} -> []
    end
  end

  defp change(socket, path, value) do
    %{cnc: cnc, controller: c} = socket.assigns
    Config.change(cnc.machine, cnc.db, c.id, path, value)
  end

  defp axis_fields, do: @axis_fields

  # Axes that have the usual settings, in the config's order.
  defp axes(settings) do
    for a <- ~w(x y z a b c), Map.has_key?(settings, "axes/#{a}/steps_per_mm"), do: a
  end

  defp unsaved?(changes, path), do: Enum.any?(changes, &(&1.path == path))

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

  defp same_value?(a, b) do
    case {Float.parse(a), Float.parse(String.trim(b))} do
      {{x, ""}, {y, ""}} -> x == y
      _ -> String.trim(a) == String.trim(b)
    end
  end

  defp waiting_text(:disconnected), do: "Not connected yet: waiting for the controller."
  defp waiting_text(:connecting), do: "Connecting…"
  defp waiting_text(_), do: "The machine is moving: the configuration is available once it stops."

  defp dom_id(name), do: String.replace(name, ~r/[^A-Za-z0-9_-]/, "-")

  defp size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"

  defp error_text(:invalid_name),
    do: "Use letters, digits, - and _ for the file name (it ends in .yaml)."

  defp error_text(:unknown_setting), do: "The controller has no such setting."

  defp error_text(:invalid_setting),
    do: "A setting is a path like axes/x/max_rate_mm_per_min."

  defp error_text(:invalid_value), do: "Enter a value (no = or line breaks)."
  defp error_text(:no_active_file), do: "The controller doesn't say which file it loaded."

  defp error_text({:not_applied, why}),
    do: "The controller didn't apply it (#{why}). Some settings only change in the file."

  defp error_text(:wiring),
    do: "That's wiring (pins, stepping): it's set by the board and only changes in a config file."

  defp error_text(:exists), do: "There's already a file with that name."
  defp error_text(:active), do: "That's the file the controller loads: switch to another first."
  defp error_text(:not_found), do: "That file isn't on the controller."
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
      homing: "Homing",
      busy: "Busy"
    }[state]
  end
end
