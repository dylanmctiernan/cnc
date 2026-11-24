defmodule CNCWeb.MachineLive do
  @moduledoc """
  The machine screen: bed view, position readout, and jog controls.

  Renders only what `CNC.Machine` reports. Keyboard jogging lives in the
  `JogKeys` hook; the bed is drawn by the `BedView` hook from `"pos"` events.
  """
  use CNCWeb, :live_view

  # Also enforced by the router's live_session; here so the view is
  # protected however it's mounted.
  on_mount CNCWeb.Pin

  alias CNC.{Machine, Program}
  alias CNC.Machine.State

  @tiers [fine: {5, 1}, normal: {20, 5}, fast: {50, 10}]
  @steps [0.1, 1, 10, 50]
  @console_rows 200
  @fade_ms 8_000

  @impl true
  def mount(_params, session, socket) do
    cnc = CNCWeb.Instance.from_session(session)

    if connected?(socket) do
      Machine.subscribe(cnc.topic)
      Program.subscribe(cnc.program_topic)
      CNC.Controllers.subscribe(cnc.controllers_topic)
    end

    machine = Machine.status(cnc.machine)
    program = Program.current(cnc.program)
    controller = CNC.Controllers.active(cnc.controllers)

    {:ok,
     socket
     |> assign(cnc: cnc, machine: machine, controller: controller, tier: :normal, step: 10)
     |> assign(frame: :work, action_error: nil, control_mode: :joystick, step_axis: :x)
     |> assign(more?: false, dismissed: MapSet.new(), fades: %{})
     |> assign(file?: false, program: program, file_error: nil)
     |> assign(work_edit: nil)
     |> assign(zoom: if(program, do: :file, else: :bed))
     |> allow_upload(:gcode,
       accept: ~w(.nc .gcode .ngc .tap .cnc .txt),
       max_entries: 1,
       max_file_size: 20_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> assign(details?: false, polls?: false, raw_error: nil, commands?: false)
     |> assign(command_help: CNCWeb.ConsoleHelp.sections())
     |> assign(tiers: @tiers, steps: @steps)
     |> stream_configure(:console, dom_id: &"log-#{&1.id}")
     |> stream(:console, [])
     |> push_pos(machine)
     |> push_program()}
  end

  @impl true
  def handle_info({:machine, %State{} = machine}, socket) do
    socket =
      if machine.travel != socket.assigns.machine.travel,
        do: push_event(socket, "travel", %{travel: travel_list(machine.travel)}),
        else: socket

    socket =
      if machine.last_error != socket.assigns.machine.last_error,
        do: socket |> forget_note(:error) |> fade_later(:error),
        else: socket

    {:noreply, socket |> assign(machine: machine) |> push_pos(machine)}
  end

  # A note fades on its own unless it changed since the timer was set.
  def handle_info({:fade, key, ref}, socket) do
    if socket.assigns.fades[key] == ref,
      do: {:noreply, dismiss(socket, key)},
      else: {:noreply, socket}
  end

  # A new file is shown zoomed to; clearing it goes back to the whole bed.
  def handle_info({:program, program}, socket) do
    zoom = if program, do: :file, else: :bed

    {:noreply,
     socket
     |> assign(program: program, file_error: nil, zoom: zoom)
     |> push_program()
     |> push_event("zoom", %{mode: zoom})}
  end

  def handle_info({:controllers, _}, socket),
    do:
      {:noreply,
       assign(socket, controller: CNC.Controllers.active(socket.assigns.cnc.controllers))}

  def handle_info({:machine_console, entry}, socket),
    do: {:noreply, stream_insert(socket, :console, entry, limit: -@console_rows)}

  @impl true
  def handle_event("jog", %{"x" => x, "y" => y, "tier" => tier} = params, socket) do
    with {:ok, vector} <- analog_vector(x, y, params["z"] || 0), {:ok, tier} <- tier(tier) do
      Machine.jog(srv(socket), vector, tier)
    end

    {:noreply, socket}
  end

  def handle_event("jog_heartbeat", _, socket), do: tap_noreply(socket, &Machine.jog_heartbeat/1)
  def handle_event("jog_stop", _, socket), do: tap_noreply(socket, &Machine.jog_stop/1)

  # Esc: stop jogging and hold.
  def handle_event("stop", _, socket) do
    Machine.jog_stop(srv(socket))
    Machine.feed_hold(srv(socket))
    {:noreply, socket}
  end

  def handle_event("unlock", _, socket), do: tap_noreply(socket, &Machine.unlock/1)
  def handle_event("home", _, socket), do: tap_noreply(socket, &Machine.home/1)
  def handle_event("feed_hold", _, socket), do: tap_noreply(socket, &Machine.feed_hold/1)
  def handle_event("resume", _, socket), do: tap_noreply(socket, &Machine.resume/1)
  def handle_event("reset", _, socket), do: tap_noreply(socket, &Machine.reset/1)

  def handle_event("step", %{"x" => x, "y" => y} = params, socket) do
    with {:ok, vector} when vector != {0, 0, 0} <- vector(x, y, params["z"] || 0),
         do: Machine.jog_step(srv(socket), vector, socket.assigns.step)

    {:noreply, socket}
  end

  def handle_event("tier", %{"tier" => tier}, socket) do
    case tier(tier) do
      {:ok, tier} -> {:noreply, socket |> assign(tier: tier) |> push_pos(socket.assigns.machine)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("step_size", %{"mm" => mm}, socket) do
    case Enum.find(@steps, &(to_string(&1) == mm)) do
      nil -> {:noreply, socket}
      step -> {:noreply, assign(socket, step: step)}
    end
  end

  # Controller layouts: the menu. Its open state lives here, not in the DOM, so
  # status updates don't close it.
  def handle_event("toggle_more", _, socket), do: {:noreply, update(socket, :more?, &(!&1))}

  # G-code file: a dialog to upload (auto, on drop/choose) and summarise it.
  # Set a work coordinate by typing it: nothing moves (G10 L20).
  def handle_event("edit_work", %{"axis" => axis}, socket) when axis in ~w(x y z) do
    axis = String.to_existing_atom(axis)
    i = Enum.find_index([:x, :y, :z], &(&1 == axis))
    m = socket.assigns.machine
    # Work tab: where the tool is, relative to the work zero. Machine tab:
    # where the work zero is, as an absolute spot on the bed.
    edit_frame = frame(m, socket.assigns.frame)

    current =
      case edit_frame do
        :machine -> m.wco |> elem(i) |> fmt()
        :work -> m.wpos |> elem(i) |> fmt()
      end

    {:noreply,
     assign(socket,
       work_edit: %{axis: axis, frame: edit_frame, value: "", current: current, error: nil}
     )}
  end

  # The work zero row: always an absolute spot on the bed, whichever tab.
  def handle_event("edit_zero", %{"axis" => axis}, socket) when axis in ~w(x y z) do
    axis = String.to_existing_atom(axis)
    i = Enum.find_index([:x, :y, :z], &(&1 == axis))
    current = socket.assigns.machine.wco |> elem(i) |> fmt()

    {:noreply,
     assign(socket,
       work_edit: %{axis: axis, frame: :machine, value: "", current: current, error: nil}
     )}
  end

  def handle_event("work_negate", _, socket) do
    negate = fn
      "-" <> rest -> rest
      "" -> "-"
      v -> "-" <> v
    end

    {:noreply,
     update(socket, :work_edit, &%{&1 | value: negate.(String.trim(&1.value)), error: nil})}
  end

  def handle_event("work_preview", %{"value" => value}, socket),
    do: {:noreply, update(socket, :work_edit, &%{&1 | value: value, error: nil})}

  def handle_event("cancel_work", _, socket), do: {:noreply, assign(socket, work_edit: nil)}

  def handle_event("set_work", %{"value" => value}, socket) do
    %{axis: axis} = socket.assigns.work_edit

    set =
      if socket.assigns.work_edit.frame == :machine,
        do: &Machine.set_work_offset/2,
        else: &Machine.set_work_position/2

    with {:ok, v} <- parse_mm(value),
         :ok <- set.(srv(socket), [{axis, v}]) do
      {:noreply, assign(socket, work_edit: nil)}
    else
      :error ->
        {:noreply, update(socket, :work_edit, &%{&1 | error: "Type a number of mm, like 12.5."})}

      {:error, :invalid_value} ->
        {:noreply, update(socket, :work_edit, &%{&1 | error: "That's outside ±100 000 mm."})}

      {:error, :outside_travel} ->
        {:noreply,
         update(socket, :work_edit, &%{&1 | error: "That puts the work zero off the machine."})}

      {:error, :moving} ->
        {:noreply, update(socket, :work_edit, &%{&1 | error: "Wait for the machine to stop."})}

      {:error, _} ->
        {:noreply,
         update(socket, :work_edit, &%{&1 | error: "Only when the machine is Ready and stopped."})}
    end
  end

  def handle_event("toggle_zoom", _, socket) do
    zoom = if socket.assigns.zoom == :file, do: :bed, else: :file
    {:noreply, socket |> assign(zoom: zoom) |> push_event("zoom", %{mode: zoom})}
  end

  def handle_event("open_file", _, socket), do: {:noreply, assign(socket, file?: true)}
  def handle_event("close_file", _, socket), do: {:noreply, assign(socket, file?: false)}
  def handle_event("validate_upload", _, socket), do: {:noreply, assign(socket, file_error: nil)}
  def handle_event("upload", _, socket), do: {:noreply, socket}

  def handle_event("clear_program", _, socket) do
    Program.clear(socket.assigns.cnc.program)
    {:noreply, socket}
  end

  def handle_event("close_more", _, socket), do: {:noreply, assign(socket, more?: false)}

  def handle_event("dismiss", %{"note" => "error"}, socket),
    do: {:noreply, dismiss(socket, :error)}

  def handle_event("dismiss", %{"note" => "action"}, socket),
    do: {:noreply, dismiss(socket, :action)}

  def handle_event("dismiss", %{"note" => "travel"}, socket),
    do: {:noreply, dismiss(socket, :travel)}

  def handle_event("control_mode", %{"mode" => mode}, socket) when mode in ~w(joystick step zero),
    do: {:noreply, assign(socket, control_mode: String.to_existing_atom(mode))}

  def handle_event("step_axis", %{"axis" => axis}, socket) when axis in ~w(x y z),
    do: {:noreply, assign(socket, step_axis: String.to_existing_atom(axis))}

  def handle_event("frame", %{"frame" => frame}, socket) when frame in ~w(work machine),
    do: {:noreply, assign(socket, frame: String.to_existing_atom(frame))}

  def handle_event("zero", %{"axes" => axes}, socket) do
    axes = for c <- String.graphemes(axes), c in ~w(x y z), do: String.to_existing_atom(c)
    if axes != [], do: Machine.set_work_zero(srv(socket), axes)
    {:noreply, set_action_error(socket, nil)}
  end

  def handle_event("go_to_zero", _, socket) do
    error =
      case Machine.go_to_work_zero(srv(socket)) do
        :ok ->
          nil

        {:error, :outside_travel} ->
          "The work zero is outside the travel area, so the machine won't go there."

        {:error, :no_work_offset} ->
          "The controller hasn't reported a work offset yet. Try again in a moment."

        {:error, :moving} ->
          "Wait for the machine to stop, then try again."

        {:error, {:invalid_state, _}} ->
          nil
      end

    {:noreply, set_action_error(socket, error)}
  end

  # Console traffic is only subscribed to while the panel is open. Subscribe
  # before loading history; overlapping entries share a DOM id, so no dupes.
  def handle_event("toggle_details", _, %{assigns: %{details?: false}} = socket) do
    Machine.subscribe_console(socket.assigns.cnc.topic)

    {:noreply,
     socket
     |> assign(details?: true)
     |> stream(:console, Machine.console(srv(socket)), reset: true)}
  end

  def handle_event("toggle_details", _, socket) do
    Machine.unsubscribe_console(socket.assigns.cnc.topic)
    Machine.unsubscribe_polls(socket.assigns.cnc.topic)

    {:noreply,
     socket |> assign(details?: false, polls?: false) |> stream(:console, [], reset: true)}
  end

  def handle_event("toggle_polls", _, %{assigns: %{polls?: polls?}} = socket) do
    topic = socket.assigns.cnc.topic
    if polls?, do: Machine.unsubscribe_polls(topic), else: Machine.subscribe_polls(topic)
    {:noreply, assign(socket, polls?: !polls?)}
  end

  def handle_event("send_raw", %{"line" => line}, socket) do
    error =
      case Machine.send_raw(srv(socket), line) do
        :ok ->
          nil

        {:error, :invalid_line} ->
          if String.trim(line) == "", do: nil, else: "Send one line of text."

        {:error, {:invalid_state, state}} ->
          "Can't send while #{busy_word(state)}."
      end

    {:noreply, assign(socket, raw_error: error)}
  end

  def handle_event("toggle_commands", _, socket),
    do: {:noreply, update(socket, :commands?, &(!&1))}

  def handle_event("ask_controller", _, socket),
    do: handle_event("send_raw", %{"line" => "$"}, socket)

  def handle_event("clear_console", _, socket),
    do: {:noreply, stream(socket, :console, [], reset: true)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="jog-keys" phx-hook="JogKeys" data-tier={@tier} hidden></div>

      <%!-- One structure, two layouts (assets/css/app.css):
           touch and small screens get the controller (readout, map, controller,
           Stop dock); a wide screen with a mouse gets the workstation (map,
           readout and jog panel, details, docked console, Stop in the bar). --%>
      <div class={["cnc", @details? && "has-console"]} data-mode={@control_mode}>
        <header class="cnc-bar">
          <div class={"cnc-state cnc-state--#{@machine.state}"} role="status">
            {state_label(@machine)}
          </div>
          <dl class="cnc-meta">
            <div>
              <dt>controller</dt>
              <dd class={if @machine.connected?, do: "is-on", else: "is-off"}>
                <.link navigate={~p"/controllers"} class="cnc-meta-link" title="Controllers">
                  {controller_name(@controller, @machine)} {if @machine.connected?,
                    do: "connected",
                    else: "not connected"}
                </.link>
              </dd>
            </div>
            <div class="cnc-meta-linkinfo" id="header-link">
              <dt>link</dt>
              <dd title={link_title(@controller, @machine)}>{link_label(@controller, @machine)}</dd>
            </div>
            <div class="cnc-meta-firmware">
              <dt>firmware</dt>
              <dd title={full_firmware(@machine.controller_info)}>
                {firmware_label(@machine.controller_info)}
              </dd>
            </div>
            <div class="cnc-meta-reports">
              <dt>reports</dt>
              <dd>{controller_label(@machine)}</dd>
            </div>
          </dl>
          <div class="cnc-actions">
            <button
              type="button"
              class="cnc-btn cnc-stop"
              phx-click="stop"
              disabled={!@machine.connected?}
              title="Cancel any jog and hold (Esc)"
            >
              Stop
            </button>
            <button
              type="button"
              class="cnc-btn"
              phx-click="feed_hold"
              disabled={!@machine.connected?}
            >
              Hold
            </button>
            <button type="button" class="cnc-btn" phx-click="resume" disabled={!@machine.connected?}>
              Resume
            </button>
            <button type="button" class="cnc-btn" phx-click="reset" disabled={!@machine.connected?}>
              Reset
            </button>
            <button type="button" id="open-file" class="cnc-btn" phx-click="open_file">
              Open file
            </button>
            <button
              type="button"
              class="cnc-btn"
              phx-click="toggle_details"
              aria-pressed={to_string(@details?)}
              aria-controls="console"
            >
              Console
            </button>
          </div>
          <%!-- Controller: the rarely used things live in a menu --%>
          <div class="cnc-more">
            <button
              type="button"
              class="cnc-btn"
              phx-click="toggle_more"
              aria-expanded={to_string(@more?)}
              aria-controls="more-menu"
            >
              Menu
            </button>
            <div :if={@more?} id="more-menu" class="cnc-more-menu" phx-click-away="close_more">
              <p class="cnc-sub">{firmware_label(@machine.controller_info)}</p>
              <button
                type="button"
                class="cnc-btn"
                phx-click={JS.push("feed_hold") |> JS.push("close_more")}
                disabled={!@machine.connected?}
              >
                Hold
              </button>
              <button
                type="button"
                class="cnc-btn"
                phx-click={
                  JS.dispatch("bed:clear-trail", to: "#bed")
                  |> JS.push("close_more")
                }
              >
                Clear trail
              </button>
              <button
                type="button"
                class="cnc-btn"
                phx-click={JS.push("open_file") |> JS.push("close_more")}
              >
                {if @program, do: "File: #{@program.name}", else: "Open file"}
              </button>
              <button
                type="button"
                class="cnc-btn"
                phx-click={JS.push("toggle_details") |> JS.push("close_more")}
              >
                {if @details?, do: "Hide console", else: "Console"}
              </button>
              <.link navigate={~p"/controllers"} class="cnc-btn">
                Controller: {controller_name(@controller, @machine)}
              </.link>
              <button
                type="button"
                class="cnc-btn"
                phx-click={JS.push("reset") |> JS.push("close_more")}
                disabled={!@machine.connected?}
              >
                Reset controller
              </button>
            </div>
          </div>
        </header>

        <div class="cnc-messages">
          <p :if={@controller == nil and @machine.adapter == nil} class="cnc-note" id="no-controller">
            No controller chosen.
            <.link navigate={~p"/controllers"} class="cnc-meta-link">Add or pick one</.link>
            to connect.
          </p>
          <div :if={@machine.state == :alarm} class="cnc-lock" role="alert">
            <span class="cnc-lock-tag">Locked</span>
            <p>
              {alarm_text(@machine.alarm)}
              <span :if={@machine.homing_enabled? == false}>
                This controller has homing turned off ($22), so unlock to continue.
              </span>
            </p>
            <div class="cnc-row">
              <button
                type="button"
                class={["cnc-btn", @machine.homing_enabled? != false && "cnc-btn--primary"]}
                phx-click="home"
                disabled={@machine.homing_enabled? == false}
              >
                Home
              </button>
              <button
                type="button"
                class={["cnc-btn", @machine.homing_enabled? == false && "cnc-btn--primary"]}
                phx-click="unlock"
              >
                Unlock
              </button>
            </div>
          </div>
          <.note
            :if={note = not MapSet.member?(@dismissed, :error) && error_text(@machine.last_error)}
            id="note-error"
            key="error"
          >
            {note}
          </.note>
          <.note :if={@action_error} id="note-action" key="action">{@action_error}</.note>
          <.note
            :if={@machine.travel_issues != [] and not MapSet.member?(@dismissed, :travel)}
            id="note-travel"
            key="travel"
            warn
          >
            <span :for={{axis, got, max} <- @machine.travel_issues}>
              The controller reports {axis_name(axis)} travel of {round(got)} mm, more than this
              machine's {round(max)} mm. Using {round(max)} mm. Check ${travel_setting(axis)} with $$.
            </span>
          </.note>
        </div>

        <section class="cnc-view" aria-label="Bed and Z">
          <button
            :if={@program}
            id="zoom-toggle"
            type="button"
            class="cnc-btn cnc-zoom"
            phx-click="toggle_zoom"
            aria-pressed={to_string(@zoom == :file)}
          >
            {if @zoom == :file, do: "Whole bed", else: "Zoom to file"}
          </button>
          <div
            id="bed"
            class="cnc-bed"
            phx-hook="BedView"
            phx-update="ignore"
            data-travel={travel_json(@machine.travel)}
            data-x={pos(@machine, 0)}
            data-y={pos(@machine, 1)}
            data-z={pos(@machine, 2)}
            data-state={@machine.state}
            data-zoom={@zoom}
          >
            <canvas
              role="img"
              aria-label="Top-down view of the bed with the tool position, Z height, and X/Y and Z speed"
            >
            </canvas>
          </div>
        </section>

        <section class="cnc-dro" aria-label="Position">
          <div class="cnc-dro-head">
            <h2 class="cnc-h">
              {if frame(@machine, @frame) == :work, do: "Work", else: "Machine"} position
              <span class="cnc-unit">mm</span>
            </h2>
            <.frame_switch machine={@machine} frame={@frame} />
          </div>
          <span class="cnc-dro-frame" aria-hidden="true">
            {if frame(@machine, @frame) == :work, do: "work", else: "mach"}
          </span>
          <div :for={{axis, i} <- [{"X", 0}, {"Y", 1}, {"Z", 2}]} class="cnc-dro-row">
            <span class={"cnc-axis cnc-axis--#{String.downcase(axis)}"}>{axis}</span>
            <%!-- Work tab: tap the work position to type it. Machine tab: the
                 machine's actual position, which only jogging changes. --%>
            <button
              :if={@machine.wpos && frame(@machine, @frame) == :work}
              type="button"
              class="cnc-num cnc-num--edit"
              phx-click="edit_work"
              phx-value-axis={String.downcase(axis)}
              aria-label={"Set work #{axis} without moving"}
              title="Set this axis's work position without moving"
            >
              {fmt(axis_value(shown(@machine, @frame), i))}
            </button>
            <span :if={!@machine.wpos || frame(@machine, @frame) == :machine} class="cnc-num">
              {fmt(axis_value(shown(@machine, @frame), i))}
            </span>
          </div>
          <p :if={@machine.wpos} class="cnc-sub cnc-dro-other">
            {if frame(@machine, @frame) == :work, do: "machine", else: "work"} {xyz_label(
              if(frame(@machine, @frame) == :work, do: @machine.mpos, else: @machine.wpos)
            )}
          </p>
          <%!-- On both tabs, so switching doesn't move anything --%>
          <.work_zero_row :if={@machine.wco} machine={@machine} />
          <div class="cnc-row cnc-dro-tools">
            <button
              type="button"
              class="cnc-btn"
              phx-click="zero"
              phx-value-axes="xy"
              disabled={@machine.state != :idle}
            >
              Zero X/Y
            </button>
            <button
              type="button"
              class="cnc-btn is-z"
              phx-click="zero"
              phx-value-axes="z"
              disabled={@machine.state != :idle}
            >
              Zero Z
            </button>
            <button
              type="button"
              class="cnc-btn"
              phx-click="go_to_zero"
              disabled={not can_go_to_zero?(@machine)}
            >
              Go to X0 Y0
            </button>
          </div>
        </section>

        <section class="cnc-ctl" aria-label="Jog and zero">
          <div class="cnc-seg cnc-tabs" role="group" aria-label="Control mode">
            <button
              :for={{mode, label} <- [joystick: "Stick", step: "Step", zero: "Zero"]}
              type="button"
              class={["cnc-btn", "cnc-tab--#{mode}"]}
              aria-pressed={to_string(@control_mode == mode)}
              phx-click="control_mode"
              phx-value-mode={mode}
            >
              {label}
            </button>
          </div>

          <%!-- Same height in every mode, so switching never moves the map --%>
          <div class="cnc-ctl-body">
            <div
              :if={@control_mode != :zero}
              class="cnc-seg cnc-speed"
              role="group"
              aria-label="Jog speed"
            >
              <button
                :for={{tier, {xy, z}} <- @tiers}
                type="button"
                class="cnc-btn"
                aria-pressed={to_string(@tier == tier)}
                phx-click="tier"
                phx-value-tier={tier}
                title={"#{xy} mm/s X/Y, #{z} mm/s Z at full push"}
              >
                {tier}<span class="cnc-unit">{xy}/{z}</span>
              </button>
            </div>

            <div
              :if={@control_mode == :joystick}
              id="joystick"
              class="cnc-joy"
              phx-hook="Joystick"
              phx-update="ignore"
              data-tier={@tier}
              data-enabled={to_string(@machine.state in [:idle, :jogging])}
            >
              <div
                class="cnc-joy-pad"
                role="application"
                aria-label="X/Y joystick: drag to jog, release to stop"
              >
                <span class="cnc-joy-label is-y" style="top: 0.25rem; left: 50%">Y+</span>
                <span class="cnc-joy-label is-y" style="bottom: 0.25rem; left: 50%">Y−</span>
                <span class="cnc-joy-label is-x" style="left: 0.5rem; top: 50%">X−</span>
                <span class="cnc-joy-label is-x" style="right: 0.5rem; top: 50%">X+</span>
                <span class="cnc-joy-knob"></span>
              </div>
              <div
                class="cnc-joy-z"
                role="application"
                aria-label="Z slider: drag up or down to jog, release to stop"
              >
                <span class="cnc-joy-label is-z" style="top: 0.25rem; left: 50%">Z+</span>
                <span class="cnc-joy-label is-z" style="bottom: 0.25rem; left: 50%">Z−</span>
                <span class="cnc-joy-knob"></span>
              </div>
            </div>

            <%!-- Step: like a handwheel pendant. Pick the axis, pick the size,
                 then − and +. --%>
            <div :if={@control_mode == :step} class="cnc-pendant">
              <div class="cnc-seg" role="group" aria-label="Axis">
                <button
                  :for={axis <- [:x, :y, :z]}
                  type="button"
                  class={["cnc-btn", "is-#{axis}"]}
                  aria-pressed={to_string(@step_axis == axis)}
                  phx-click="step_axis"
                  phx-value-axis={axis}
                >
                  {axis |> to_string() |> String.upcase()}
                </button>
              </div>
              <div class="cnc-seg" role="group" aria-label="Step size in mm">
                <button
                  :for={mm <- @steps}
                  type="button"
                  class="cnc-btn"
                  aria-pressed={to_string(@step == mm)}
                  phx-click="step_size"
                  phx-value-mm={mm}
                >
                  {mm}
                </button>
              </div>
              <div class="cnc-pendant-go">
                <button
                  :for={dir <- [-1, 1]}
                  type="button"
                  class={["cnc-btn", "cnc-pendant-btn", "is-#{@step_axis}"]}
                  phx-click="step"
                  phx-value-x={if @step_axis == :x, do: dir, else: 0}
                  phx-value-y={if @step_axis == :y, do: dir, else: 0}
                  phx-value-z={if @step_axis == :z, do: dir, else: 0}
                  disabled={@machine.state != :idle}
                  aria-label={"Move #{String.upcase(to_string(@step_axis))} #{if dir < 0, do: "minus", else: "plus"} #{@step} mm"}
                >
                  {String.upcase(to_string(@step_axis))}{if dir < 0, do: "−", else: "+"}
                  <span class="cnc-unit">{@step} mm</span>
                </button>
              </div>
            </div>

            <%!-- Zero: set where the work is (controller layouts; the workstation
                 has these next to the readout) --%>
            <div :if={@control_mode == :zero} class="cnc-zero">
              <.frame_switch machine={@machine} frame={@frame} />
              <div class="cnc-zero-axes">
                <button
                  type="button"
                  class="cnc-btn"
                  phx-click="zero"
                  phx-value-axes="xy"
                  disabled={@machine.state != :idle}
                >
                  Zero X/Y
                </button>
                <button
                  type="button"
                  class="cnc-btn is-z"
                  phx-click="zero"
                  phx-value-axes="z"
                  disabled={@machine.state != :idle}
                >
                  Zero Z
                </button>
              </div>
              <div class="cnc-zero-axes">
                <button
                  type="button"
                  class="cnc-btn"
                  phx-click="go_to_zero"
                  disabled={not can_go_to_zero?(@machine)}
                >
                  Go to work zero
                </button>
              </div>
              <.work_zero_row :if={@machine.wco} machine={@machine} />
              <p class="cnc-sub">
                Zero X/Y at the stock's corner, Zero Z on its surface. To type a value,
                tap a work position, or the work zero above.
              </p>
            </div>
          </div>
        </section>

        <%!-- Workstation only: details and keyboard --%>
        <aside class="cnc-side" aria-label="Details and keyboard">
          <section :if={@program} class="cnc-file-side" aria-label="Loaded file">
            <.program_summary program={@program} fit={fit(@program, @machine)} />
            <div class="cnc-row">
              <button type="button" class="cnc-btn cnc-btn--quiet" phx-click="open_file">
                Open another
              </button>
              <button type="button" class="cnc-btn cnc-btn--quiet" phx-click="clear_program">
                Clear
              </button>
            </div>
          </section>
          <dl class="cnc-facts" aria-label="Controller details">
            <dt>planner</dt>
            <dd>{buffer_label(@machine.buffer, 0, "blocks")}</dd>
            <dt>serial</dt>
            <dd>{buffer_label(@machine.buffer, 1, "bytes")}</dd>
            <dt>awaiting ack</dt>
            <dd>{pluralize(@machine.awaiting_ack, "line")}</dd>
            <dt>work offset</dt>
            <dd>{xyz_label(@machine.wco)}</dd>
            <dt>travel</dt>
            <dd>
              {travel_label(@machine.travel)}
              <span class="cnc-sub-inline">
                {if @machine.travel_source == :controller,
                  do: "from the controller",
                  else: "from config"}
              </span>
            </dd>
            <dt :if={@machine.alarm}>locked because</dt>
            <dd :if={@machine.alarm}>{lock_label(@machine.alarm)}</dd>
          </dl>
          <dl class="cnc-keys" aria-label="Keyboard">
            <dt>← → ↑ ↓</dt>
            <dd>Jog X/Y while held</dd>
            <dt>PgUp PgDn</dt>
            <dd>Jog Z while held (fn+↑ fn+↓ on a Mac)</dd>
            <dt>Shift</dt>
            <dd>Fast while held</dd>
            <dt>Option</dt>
            <dd>Fine while held</dd>
            <dt>Esc</dt>
            <dd>Stop and hold, always</dd>
          </dl>
          <button
            type="button"
            class="cnc-btn cnc-btn--quiet"
            phx-click={JS.dispatch("bed:clear-trail", to: "#bed")}
          >
            Clear trail
          </button>
        </aside>

        <div
          :if={@work_edit}
          id="work-dialog"
          class="cnc-file-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="work-title"
          phx-window-keydown="cancel_work"
          phx-key="Escape"
        >
          <form
            id="work-form"
            class="cnc-review-box cnc-work-box"
            phx-change="work_preview"
            phx-submit="set_work"
            phx-click-away="cancel_work"
          >
            <h2 id="work-title" class="cnc-page-title">
              {if @work_edit.frame == :machine,
                do: "Set #{String.upcase(to_string(@work_edit.axis))} work zero",
                else: "Set #{String.upcase(to_string(@work_edit.axis))} position"}
            </h2>
            <div class="cnc-work-field">
              <label for="work-value">
                {if @work_edit.frame == :machine,
                  do: "Work zero at machine #{String.upcase(to_string(@work_edit.axis))} =",
                  else: "Tool is at #{String.upcase(to_string(@work_edit.axis))} ="}
              </label>
              <input
                id="work-value"
                name="value"
                value={@work_edit.value}
                placeholder={@work_edit.current}
                inputmode="decimal"
                autocomplete="off"
                phx-mounted={JS.focus()}
              />
              <span class="cnc-unit">mm</span>
              <%!-- iPhone decimal keypads have no minus key --%>
              <button
                type="button"
                class="cnc-btn"
                phx-click="work_negate"
                aria-label="Change sign"
              >
                ±
              </button>
            </div>
            <p class={[
              "cnc-sub",
              match?({:outside, _, _}, work_check(@work_edit, @machine)) && "cnc-set-error"
            ]}>
              {work_preview(@work_edit, @machine)}
            </p>
            <p :if={@work_edit.error} class="cnc-set-error">{@work_edit.error}</p>
            <div class="cnc-row">
              <button type="button" class="cnc-btn" phx-click="cancel_work">Cancel</button>
              <button
                type="submit"
                class="cnc-btn cnc-btn--primary"
                disabled={
                  @machine.state != :idle or
                    not match?({:ok, _}, work_check(@work_edit, @machine))
                }
              >
                Set {String.upcase(to_string(@work_edit.axis))}
              </button>
            </div>
          </form>
        </div>

        <div
          :if={@file?}
          id="file-dialog"
          class="cnc-file-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="file-title"
          phx-window-keydown="close_file"
          phx-key="Escape"
        >
          <div class="cnc-review-box cnc-file-box" phx-click-away="close_file">
            <h2 id="file-title" class="cnc-page-title">G-code file</h2>
            <form id="upload-form" phx-change="validate_upload" phx-submit="upload">
              <label class="cnc-drop" phx-drop-target={@uploads.gcode.ref}>
                <.live_file_input upload={@uploads.gcode} class="cnc-sr-only" />
                <span class="cnc-drop-main">Choose a file</span>
                <span class="cnc-sub">
                  or drop it here. .nc, .gcode, .ngc, .tap; up to 20 MB.
                </span>
              </label>
              <%= for entry <- @uploads.gcode.entries do %>
                <p class="cnc-sub">
                  {entry.client_name}: {if entry.progress < 100,
                    do: "uploading #{entry.progress}%",
                    else: "reading"}
                </p>
                <p :for={err <- upload_errors(@uploads.gcode, entry)} class="cnc-set-error">
                  {upload_error(err)}
                </p>
              <% end %>
              <p :for={err <- upload_errors(@uploads.gcode)} class="cnc-set-error">
                {upload_error(err)}
              </p>
              <p :if={@file_error} class="cnc-set-error">{@file_error}</p>
            </form>
            <.program_summary :if={@program} program={@program} fit={fit(@program, @machine)} />
            <div class="cnc-row">
              <button :if={@program} type="button" class="cnc-btn" phx-click="clear_program">
                Clear file
              </button>
              <button type="button" class="cnc-btn cnc-btn--primary" phx-click="close_file">
                {if @program, do: "Show on the map", else: "Close"}
              </button>
            </div>
          </div>
        </div>

        <section :if={@details?} id="console" class="cnc-console" aria-label="Controller console">
          <div class="cnc-console-bar">
            <h2 class="cnc-h">Console</h2>
            <label class="cnc-check">
              <input type="checkbox" checked={@polls?} phx-click="toggle_polls" />
              <span><span class="cnc-wide-only">Show </span>status polls</span>
            </label>
            <button type="button" class="cnc-btn cnc-btn--quiet" phx-click="clear_console">
              Clear
            </button>
            <button
              type="button"
              class="cnc-btn cnc-btn--quiet"
              phx-click="toggle_commands"
              aria-expanded={to_string(@commands?)}
              aria-controls="console-help"
            >
              {if @commands?, do: "Hide commands", else: "Commands"}
            </button>
            <button type="button" class="cnc-btn cnc-console-close" phx-click="toggle_details">
              Close
            </button>
          </div>
          <div :if={@commands?} id="console-help" class="cnc-help">
            <p class="cnc-help-lead">
              Click a command to put it in the input below; nothing is sent until you press Enter.
              <button type="button" class="cnc-link" phx-click="ask_controller">
                Ask the controller for its own list
              </button>
            </p>
            <p :if={@machine.adapter == "FakeSim"} class="cnc-help-note">
              The fake sim understands $, $$, $X, $H, $J=, $130–$132, ?, ! and ~.
              A real controller answers the rest.
            </p>
            <section :for={section <- @command_help} class="cnc-help-section">
              <h3 class="cnc-help-title">{section.title}</h3>
              <p :if={section.note} class="cnc-help-note">{section.note}</p>
              <dl class="cnc-help-list">
                <%= for item <- section.items do %>
                  <dt>
                    <button
                      type="button"
                      class="cnc-help-cmd"
                      phx-click={
                        JS.dispatch("console:insert", to: "#console-input", detail: %{text: item.cmd})
                      }
                    >
                      {item.cmd}
                    </button>
                  </dt>
                  <dd>
                    {item.desc}
                    <span :if={item.firmware} class="cnc-help-tag">{item.firmware}</span>
                  </dd>
                <% end %>
              </dl>
            </section>
          </div>
          <ol id="console-log" class="cnc-log" phx-update="stream" phx-hook="ConsoleScroll">
            <li
              :for={{dom_id, entry} <- @streams.console}
              id={dom_id}
              class={["cnc-log-row", "is-#{entry.dir}", tone(entry)]}
            >
              <time>{clock(entry.at)}</time>
              <span class="cnc-log-dir" title={if entry.dir == :out, do: "Sent", else: "Received"}>
                {if entry.dir == :out, do: "→", else: "←"}
              </span>
              <span class="cnc-log-text">{entry.text}</span>
            </li>
          </ol>
          <form
            id="console-input"
            class="cnc-term"
            phx-submit="send_raw"
            phx-hook="ConsoleInput"
            autocomplete="off"
          >
            <label for="console-line" class="cnc-term-prompt">→</label>
            <input
              id="console-line"
              name="line"
              type="text"
              spellcheck="false"
              autocapitalize="off"
              placeholder="Send a command to the controller, e.g. $$ or $G"
              aria-describedby="console-hint"
            />
            <button type="submit" class="cnc-btn">Send</button>
          </form>
          <p id="console-hint" class={["cnc-term-hint", @raw_error && "is-error"]}>
            {@raw_error ||
              "Typed moves skip the jog safety stop and the travel limit. ↑ and ↓ recall earlier commands."}
          </p>
        </section>
        <%!-- Controller: Stop always in reach, at the bottom (thumb zone) --%>
        <nav class="cnc-dock" aria-label="Stop and resume">
          <button
            type="button"
            class="cnc-btn cnc-stop"
            phx-click="stop"
            disabled={!@machine.connected?}
          >
            Stop
          </button>
          <button type="button" class="cnc-btn" phx-click="resume" disabled={!@machine.connected?}>
            Resume
          </button>
        </nav>
      </div>
    </Layouts.app>
    """
  end

  attr :machine, State, required: true
  attr :frame, :atom, required: true

  defp frame_switch(assigns) do
    ~H"""
    <div class="cnc-seg cnc-seg--small cnc-frame" role="group" aria-label="Coordinates">
      <button
        :for={f <- [:work, :machine]}
        type="button"
        class="cnc-btn"
        aria-pressed={to_string(frame(@machine, @frame) == f)}
        phx-click="frame"
        phx-value-frame={f}
        disabled={f == :work and is_nil(@machine.wpos)}
      >
        {f}
      </button>
    </div>
    """
  end

  defp can_go_to_zero?(machine),
    do: machine.state == :idle and not machine.moving? and not is_nil(machine.wco)

  ## Helpers

  # Notes: errors and action messages fade after @fade_ms; any note can be
  # closed. Closing only hides it on this screen; a new error shows again.
  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :warn, :boolean, default: false
  slot :inner_block, required: true

  defp note(assigns) do
    ~H"""
    <div id={@id} class={["cnc-note", @warn && "cnc-note--warn"]} role="status">
      <p>{render_slot(@inner_block)}</p>
      <button
        type="button"
        class="cnc-note-close"
        phx-click="dismiss"
        phx-value-note={@key}
        aria-label="Close message"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    """
  end

  defp set_action_error(socket, error) do
    socket |> assign(action_error: error) |> fade_later(:action)
  end

  defp fade_later(socket, key) do
    ref = make_ref()
    Process.send_after(self(), {:fade, key, ref}, @fade_ms)
    update(socket, :fades, &Map.put(&1, key, ref))
  end

  defp forget_note(socket, key), do: update(socket, :dismissed, &MapSet.delete(&1, key))

  defp dismiss(socket, :action), do: assign(socket, action_error: nil)
  defp dismiss(socket, key), do: update(socket, :dismissed, &MapSet.put(&1, key))

  defp tap_noreply(socket, fun) do
    fun.(srv(socket))
    {:noreply, socket}
  end

  # The machine this screen drives (see CNCWeb.Instance).
  defp srv(socket), do: socket.assigns.cnc.machine

  defp push_pos(socket, %State{mpos: {x, y, z}} = m) do
    {jx, jy, jz} = m.jog
    wco = if m.wco, do: Tuple.to_list(m.wco)

    push_event(socket, "pos", %{
      x: x,
      y: y,
      z: z,
      state: m.state,
      jog: [jx, jy, jz],
      wco: wco,
      speed: speed_payload(m, socket.assigns.tier)
    })
  end

  defp push_pos(socket, _), do: socket

  # Where the work zero sits on the bed (machine coordinates). Each value is
  # tappable: it's the number you change.
  attr :machine, State, required: true
  attr :class, :string, default: nil

  defp work_zero_row(assigns) do
    ~H"""
    <div class={["cnc-zero-row", @class]} role="group" aria-label="Work zero on the bed">
      <span class="cnc-sub">Work zero at</span>
      <button
        :for={{axis, i} <- [{"X", 0}, {"Y", 1}, {"Z", 2}]}
        type="button"
        class="cnc-zero-val"
        phx-click="edit_zero"
        phx-value-axis={String.downcase(axis)}
        aria-label={"Set the work #{axis} zero on the bed"}
      >
        <span class={"cnc-axis cnc-axis--#{String.downcase(axis)}"}>{axis}</span>
        {fmt(elem(@machine.wco, i))}
      </button>
    </div>
    """
  end

  attr :program, Program, required: true
  attr :fit, :any, required: true

  defp program_summary(assigns) do
    ~H"""
    <div class="cnc-file-summary">
      <p class="cnc-file-name">{@program.name}</p>
      <dl class="cnc-facts">
        <dt>size</dt>
        <dd>{size_label(@program.gcode.cut_bounds)}</dd>
        <dt>depth</dt>
        <dd>{depth_label(@program.gcode.cut_bounds)}</dd>
        <dt>time</dt>
        <dd>{duration_label(@program.gcode.seconds)}</dd>
        <dt>lines</dt>
        <dd>{@program.gcode.lines} ({kb(@program.bytes)})</dd>
        <dt :if={@program.gcode.tools != []}>bits</dt>
        <dd :if={@program.gcode.tools != []}>
          {Enum.map_join(@program.gcode.tools, ", ", &"T#{&1}")}: bit changes aren't handled yet
        </dd>
      </dl>
      <p :if={@fit == :no_work_zero} class="cnc-note">
        The controller hasn't reported a work zero yet, so the fit can't be checked.
      </p>
      <p :if={@fit == []} class="cnc-file-ok">Fits the travel from the current work zero.</p>
      <div :if={is_list(@fit) and @fit != []} class="cnc-note cnc-note--warn">
        <p>From the current work zero it won't fit:</p>
        <ul class="cnc-fit-issues">
          <li :for={issue <- @fit}>{fit_issue(issue)}</li>
        </ul>
      </div>
      <ul :if={@program.gcode.warnings != []} class="cnc-file-warnings">
        <li :for={w <- @program.gcode.warnings}>{warning_label(w)}</li>
      </ul>
    </div>
    """
  end

  # "12.5", "12,5" (comma keypads), "5.", "-.5", "+3"
  defp parse_mm(value) do
    v = value |> String.trim() |> String.replace(",", ".") |> String.replace_prefix("+", "")
    v = if String.ends_with?(v, "."), do: v <> "0", else: v
    v = String.replace(v, ~r/^(-?)\./, "\\g{1}0.")

    case Float.parse(v) do
      {f, ""} -> {:ok, f}
      _ -> :error
    end
  end

  # Where a typed work position puts the work zero, in machine coordinates,
  # and whether that's inside the travel (Machine refuses it otherwise).
  defp work_check(%{axis: axis, value: value} = edit, %State{mpos: mpos, travel: travel})
       when mpos != nil do
    i = Enum.find_index([:x, :y, :z], &(&1 == axis))
    {lo, hi} = elem(travel, i)

    case parse_mm(value) do
      {:ok, v} ->
        # Typed on the machine tab, the value is the zero itself.
        zero = if Map.get(edit, :frame) == :machine, do: v, else: elem(mpos, i) - v

        if zero >= lo - 0.001 and zero <= hi + 0.001,
          do: {:ok, zero},
          else: {:outside, zero, {lo, hi}}

      :error ->
        :error
    end
  end

  defp work_check(_, _), do: :error

  # Where the zero lands, said relative to the tool (machine origin is
  # front-left, Z up): a positive X means the zero is to the tool's left.
  defp work_preview(%{axis: axis, value: value} = edit, machine) do
    name = String.upcase(to_string(axis))
    i = Enum.find_index([:x, :y, :z], &(&1 == axis))

    # Either way, say it relative to the tool: v is the tool's work position.
    tool_at =
      case {Map.get(edit, :frame), parse_mm(value), machine.mpos} do
        {:machine, {:ok, zero}, {_, _, _} = mpos} -> {:ok, elem(mpos, i) - zero}
        {_, parsed, _} -> parsed
      end

    case {work_check(edit, machine), tool_at} do
      {{:ok, _}, {:ok, v}} when abs(v) < 0.0005 ->
        "#{name}0 will be right here, at the tool. Nothing moves."

      {{:ok, _}, {:ok, v}} ->
        "#{name}0 will be #{mm(abs(v))} mm #{zero_side(axis, v)} the tool. Nothing moves."

      {{:outside, _, {lo, hi}}, _} ->
        "That puts #{name}0 off the machine (#{name} runs #{mm(lo)} to #{mm(hi)})."

      _ when edit.frame == :machine ->
        "Type where the work zero is on the bed, in machine coordinates. Nothing moves."

      _ ->
        "Type where the tool is, measured from the zero you want. Nothing moves."
    end
  end

  defp zero_side(:x, v) when v > 0, do: "to the left of"
  defp zero_side(:x, _), do: "to the right of"
  defp zero_side(:y, v) when v > 0, do: "in front of"
  defp zero_side(:y, _), do: "behind"
  defp zero_side(:z, v) when v > 0, do: "below"
  defp zero_side(:z, _), do: "above"

  defp size_label(nil), do: "no cutting moves"

  defp size_label({{x0, x1}, {y0, y1}, _}),
    do: "#{mm(x1 - x0)} × #{mm(y1 - y0)} mm (X #{mm(x0)} to #{mm(x1)}, Y #{mm(y0)} to #{mm(y1)})"

  defp depth_label(nil), do: "—"
  defp depth_label({_, _, {z0, _}}), do: "down to Z #{mm(z0)} mm"

  defp duration_label(s) when s < 60, do: "about #{max(round(s), 1)} s"
  defp duration_label(s) when s < 3600, do: "about #{round(s / 60)} min"

  defp duration_label(s),
    do: "about #{div(round(s / 60), 60)} h #{rem(round(s / 60), 60)} min"

  defp kb(bytes) when bytes < 1024 * 1024, do: "#{max(round(bytes / 1024), 1)} KB"
  defp kb(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"

  # One decimal, without a trailing ".0": 227, 86.9, -6.
  defp mm(v),
    do: v |> Float.round(1) |> :erlang.float_to_binary(decimals: 1) |> String.trim_trailing(".0")

  # Machine origin is front-left, Z at the top: say which edge, and what to do.
  defp fit_issue({:z, :high, out}),
    do:
      "It lifts Z #{mm(out)} mm above the top of travel. Zero Z on the stock's surface " <>
        "(at least #{mm(out)} mm below the top)."

  defp fit_issue({:z, :low, out}),
    do: "It cuts #{mm(out)} mm deeper than Z can reach. Raise the stock, or zero Z higher."

  defp fit_issue({axis, side, out}) do
    edge =
      case {axis, side} do
        {:x, :low} -> "left"
        {:x, :high} -> "right"
        {:y, :low} -> "front"
        {:y, :high} -> "back"
      end

    "It goes #{mm(out)} mm past the #{edge} edge (#{axis |> to_string() |> String.upcase()}). " <>
      "Move the work zero #{mm(out)} mm #{opposite(edge)}."
  end

  defp opposite("left"), do: "right"
  defp opposite("right"), do: "left"
  defp opposite("front"), do: "back"
  defp opposite("back"), do: "front"

  defp warning_label(%{kind: kind, line: line, count: count}) do
    where =
      cond do
        line == 0 -> ""
        count == 1 -> " (line #{line})"
        true -> " (#{count} times, first on line #{line})"
      end

    warning_text(kind) <> where
  end

  defp warning_text(:inches), do: "Inch units: converted to mm"
  defp warning_text(:no_feed), do: "Cutting moves without a feed rate: left out of the time"
  defp warning_text(:machine_coordinates), do: "G53 machine-coordinate moves: not drawn"

  defp warning_text(:other_work_offset),
    do: "Another work offset (G55–G59): drawn as the current one"

  defp warning_text(:predefined_position), do: "G28/G30 moves to a stored position: not drawn"
  defp warning_text(:coordinate_offset), do: "G92/G10 offset changes: ignored by the preview"
  defp warning_text(:probing), do: "Probing (G38): not drawn"
  defp warning_text(:canned_cycle), do: "Drilling cycles (G81–G89): not drawn"
  defp warning_text(:arc_plane), do: "Arcs outside the XY plane: drawn straight"
  defp warning_text(:bad_arc), do: "An arc that doesn't add up: drawn straight"
  defp warning_text(:no_motion_mode), do: "Coordinates without a move command: skipped"
  defp warning_text(:bad_line), do: "Lines that aren't G-code: skipped"
  defp warning_text({:unknown_word, l}), do: "Unknown word #{l}: ignored"
  defp warning_text({:unsupported_g, g}), do: "G#{fmt_code(g)}: not supported, ignored"
  defp warning_text({:unsupported_m, m}), do: "M#{fmt_code(m)}: not supported, ignored"

  defp fmt_code(v) when v == trunc(v), do: Integer.to_string(trunc(v))
  defp fmt_code(v), do: Float.to_string(v)

  defp upload_error(:too_large), do: "That file is over 20 MB."
  defp upload_error(:not_accepted), do: "Choose a G-code file (.nc, .gcode, .ngc, .tap)."
  defp upload_error(:too_many_files), do: "One file at a time."
  defp upload_error(err), do: "Upload failed (#{inspect(err)})."

  defp handle_progress(:gcode, entry, socket) do
    if entry.done? do
      text =
        consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

      {mx, my, _} = socket.assigns.machine.max_rate || {3000.0, 3000.0, 1200.0}

      case Program.load(entry.client_name, text,
             rapid_rate: min(mx, my),
             server: socket.assigns.cnc.program
           ) do
        {:ok, _} ->
          {:noreply, socket}

        {:error, :not_text} ->
          {:noreply, assign(socket, file_error: "That isn't a text G-code file.")}
      end
    else
      {:noreply, socket}
    end
  end

  # The toolpath for the bed view, compact: the start point, then for each
  # segment its kind and end point (float32 [kind, x, y, z]). Points closer
  # than @path_merge_mm to the last one kept (same kind) are merged: the bed
  # is drawn at around a millimetre a pixel.
  @path_merge_mm 0.25

  defp push_program(socket) do
    case socket.assigns.program do
      nil ->
        push_event(socket, "program", %{path: nil})

      %Program{name: name, gcode: gcode} ->
        push_event(socket, "program", %{name: name, path: Base.encode64(client_path(gcode.path))})
    end
  end

  defp client_path(<<>>), do: <<>>

  defp client_path(
         <<_k::binary-4, x0::float-32-little, y0::float-32-little, z0::float-32-little,
           _::binary>> = path
       ) do
    start =
      <<-1.0::float-32-little, x0::float-32-little, y0::float-32-little, z0::float-32-little>>

    min2 = @path_merge_mm * @path_merge_mm

    {acc, last, pending} =
      for <<kind::float-32-little, _::binary-12, x::float-32-little, y::float-32-little,
            z::float-32-little, _::binary-4 <- path>>,
          reduce: {[start], {-1.0, x0, y0, z0}, nil} do
        {acc, {lk, lx, ly, lz}, _pending} ->
          vertex =
            <<kind::float-32-little, x::float-32-little, y::float-32-little, z::float-32-little>>

          d2 = (x - lx) * (x - lx) + (y - ly) * (y - ly) + (z - lz) * (z - lz)

          if kind == lk and d2 < min2,
            # Too close: hold it, in case it's the last of a run.
            do: {acc, {lk, lx, ly, lz}, vertex},
            else: {[acc | vertex], {kind, x, y, z}, nil}
      end

    _ = last
    IO.iodata_to_binary(if pending, do: [acc | pending], else: acc)
  end

  # How the program's moves sit in the machine's travel from the current
  # work zero: [{axis, :low | :high, mm_outside}], or :no_work_zero.
  defp fit(%Program{gcode: %{bounds: nil}}, _machine), do: []
  defp fit(_program, %State{wco: nil}), do: :no_work_zero

  defp fit(%Program{gcode: %{bounds: bounds}}, %State{wco: wco, travel: travel}) do
    for {axis, i} <- [x: 0, y: 1, z: 2],
        {pmin, pmax} = elem(bounds, i),
        {tmin, tmax} = elem(travel, i),
        offset = elem(wco, i),
        {side, out} <- [low: tmin - (pmin + offset), high: pmax + offset - tmax],
        out > 0.0005,
        do: {axis, side, out}
  end

  # Speed meters: current X/Y and Z speed against the machine's max rate,
  # with each tier's full-deflection speed marked. All mm/min.
  defp speed_payload(%State{speed: {xy, z}, max_rate: max_rate}, tier) do
    {mx, my, mz} = max_rate || {3000.0, 3000.0, 1200.0}

    %{
      xy: xy,
      z: z,
      max: [min(mx, my), mz],
      tiers: for({name, {txy, tz}} <- @tiers, do: %{name: name, xy: txy * 60, z: tz * 60}),
      tier: tier
    }
  end

  # Joystick or keys: each component a number in -1..1.
  defp analog_vector(x, y, z) do
    with {:ok, x} <- analog(x), {:ok, y} <- analog(y), {:ok, z} <- analog(z), do: {:ok, {x, y, z}}
  end

  defp analog(v) when is_number(v) and v >= -1 and v <= 1, do: {:ok, v}

  defp analog(v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> analog(f)
      _ -> :error
    end
  end

  defp analog(_), do: :error

  # Step buttons: whole directions only.
  defp vector(x, y, z) do
    with {x, ""} when x in -1..1 <- Integer.parse(to_string(x)),
         {y, ""} when y in -1..1 <- Integer.parse(to_string(y)),
         {z, ""} when z in -1..1 <- Integer.parse(to_string(z)) do
      {:ok, {x, y, z}}
    else
      _ -> :error
    end
  end

  defp tier(tier) do
    case Enum.find(Keyword.keys(@tiers), &(to_string(&1) == tier)) do
      nil -> :error
      tier -> {:ok, tier}
    end
  end

  defp pos(%State{mpos: nil}, _axis), do: nil
  defp pos(%State{mpos: mpos}, axis), do: elem(mpos, axis)

  # The position in the chosen frame; work falls back to machine until the
  # controller has reported an offset.
  defp shown(%State{wpos: {_, _, _} = wpos}, :work), do: wpos
  defp shown(%State{mpos: mpos}, _frame), do: mpos

  defp frame(%State{wpos: nil}, _), do: :machine
  defp frame(_, frame), do: frame

  defp axis_value(nil, _i), do: nil
  defp axis_value(xyz, i), do: elem(xyz, i)

  # Positions to 0.01 mm: finer than a router cuts, and it hides the
  # controller's step and rounding noise (299.988 for 300).
  defp fmt(nil), do: "—"
  defp fmt(mm), do: :erlang.float_to_binary(Float.round(mm / 1, 2) + 0.0, decimals: 2)

  defp travel_json(travel), do: Jason.encode!(travel_list(travel))

  defp travel_list({{x0, x1}, {y0, y1}, {z0, z1}}), do: [[x0, x1], [y0, y1], [z0, z1]]
  defp travel_list(_), do: [[0, 1250], [0, 1250], [-100, 0]]

  # The active controller's name; with a link override (CNC_LINK), the link.
  defp controller_name(%CNC.Controllers.Controller{name: name}, _machine), do: name
  defp controller_name(nil, %State{adapter: nil}), do: "No controller"
  defp controller_name(nil, machine), do: adapter_label(machine.adapter)

  # How the app reaches the controller; a sim says so (it's not a machine).
  defp link_label(%CNC.Controllers.Controller{link: link}, _machine), do: short_link(link)
  defp link_label(nil, %State{adapter: nil}), do: "None"
  defp link_label(nil, %State{adapter: "FakeSim"}), do: short_link(%{type: :fake_sim})
  defp link_label(nil, %State{adapter: "FluidNCSim"}), do: short_link(%{type: :fluidnc_sim})
  defp link_label(nil, %State{adapter: "UART"}), do: "USB"
  defp link_label(nil, %State{adapter: "TCP"}), do: "Wi-Fi"
  defp link_label(nil, %State{adapter: other}), do: other

  defp short_link(%{type: :fluidnc_sim}), do: "This computer (sim)"
  defp short_link(%{type: :fake_sim}), do: "Built in (sim)"
  defp short_link(%{type: :serial, port: port}), do: "USB " <> Path.basename(port)
  defp short_link(%{type: :tcp, host: host}), do: "Wi-Fi " <> host

  defp link_title(%CNC.Controllers.Controller{link: link}, _),
    do: CNC.Controllers.Controller.describe_link(link)

  defp link_title(nil, _), do: "Set by CNC_LINK"

  defp adapter_label("FakeSim"), do: "Fake sim"
  defp adapter_label("FluidNCSim"), do: "FluidNC sim"
  defp adapter_label(nil), do: ""
  defp adapter_label(name), do: name

  defp state_label(%State{state: :busy, controller: :door}), do: "Door open"
  defp state_label(%State{state: :busy, controller: :hold}), do: "On hold"

  defp state_label(%State{state: state}) do
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

  defp alarm_text(:connect),
    do:
      "The position isn't confirmed since connecting. Home to set it, or unlock to jog from here."

  defp alarm_text(:reset),
    do: "The controller restarted. Home to set the position, or unlock to jog from here."

  defp alarm_text({:alarm, code}), do: "#{alarm_cause(code)} Home or unlock once it's safe."
  defp alarm_text(_), do: "The controller is in alarm. Home or unlock once it's safe."

  defp alarm_cause(1), do: "A limit switch was hit."
  defp alarm_cause(2), do: "A move would have left the travel area."
  defp alarm_cause(3), do: "The controller was reset while moving, so the position may be off."
  defp alarm_cause(code) when code in 6..9, do: "Homing didn't complete."
  defp alarm_cause(code), do: "The controller raised alarm #{code}."

  defp firmware_label(%{firmware: nil}), do: "—"
  defp firmware_label(%{firmware: fw, version: nil}), do: fw

  # FluidNC's version line repeats itself ("4.1 FluidNC v4.1.1 (HEAD-…)
  # (macos-capture)"): show "FluidNC v4.1.1", the rest on hover.
  defp firmware_label(%{firmware: fw, version: v}) do
    case Regex.run(~r/FluidNC (v[\w.]+)/, v) do
      [_, release] -> "FluidNC #{release}"
      nil -> "#{fw} #{v}"
    end
  end

  defp full_firmware(%{firmware: nil}), do: nil
  defp full_firmware(%{firmware: fw, version: v}), do: String.trim("#{fw} #{v}")

  defp controller_label(%State{controller: nil}), do: "—"

  defp controller_label(%State{controller: c, substate: sub}) do
    name = c |> to_string() |> String.capitalize()
    if sub, do: "#{name}:#{sub}", else: name
  end

  defp buffer_label(nil, _i, _unit), do: "Not reported"
  defp buffer_label(buffer, i, unit), do: "#{elem(buffer, i)} #{unit} free"

  defp pluralize(1, word), do: "1 #{word}"
  defp pluralize(n, word), do: "#{n} #{word}s"

  defp xyz_label(nil), do: "Not reported yet"
  defp xyz_label({x, y, z}), do: "X #{fmt(x)}, Y #{fmt(y)}, Z #{fmt(z)}"

  defp travel_label({{x0, x1}, {y0, y1}, {z0, z1}}),
    do:
      "X #{round(x0)} to #{round(x1)}, Y #{round(y0)} to #{round(y1)}, Z #{round(z0)} to #{round(z1)} mm"

  defp travel_label(_), do: "—"

  defp lock_label(:connect), do: "New connection"
  defp lock_label(:reset), do: "Controller restarted"
  defp lock_label(:reported), do: "Controller reports alarm"
  defp lock_label({:alarm, code}), do: "ALARM:#{code}"

  defp tone(%{dir: :in, text: "error:" <> _}), do: "is-error"
  defp tone(%{dir: :in, text: "ALARM:" <> _}), do: "is-alarm"
  defp tone(%{dir: :in, text: "ok"}), do: "is-ok"
  defp tone(%{dir: :in, text: "$" <> _}), do: "is-setting"
  defp tone(%{dir: :in, text: "[MSG:" <> _}), do: "is-msg"
  defp tone(%{kind: :poll}), do: "is-poll"
  defp tone(%{kind: :realtime}), do: "is-realtime"
  defp tone(_), do: nil

  defp clock({{h, m, s}, ms}),
    do: :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [h, m, s, ms]) |> to_string()

  defp axis_name(axis), do: axis |> to_string() |> String.upcase()

  defp travel_setting(:x), do: 130
  defp travel_setting(:y), do: 131
  defp travel_setting(:z), do: 132

  defp busy_word(:jogging), do: "jogging"
  defp busy_word(:homing), do: "homing"
  defp busy_word(:connecting), do: "connecting"
  defp busy_word(:disconnected), do: "disconnected"
  defp busy_word(state), do: to_string(state)

  defp error_text(nil), do: nil
  defp error_text({:jog, :heartbeat_lost}), do: "Jog stopped: the keyboard stopped responding."

  defp error_text({:link, :no_response}),
    do: "The controller stopped answering, so the link was dropped and is reconnecting."

  defp error_text({:error, 15}), do: "Stopped: that move would leave the travel area."
  defp error_text({:error, 8}), do: "The controller wasn't ready for that command."

  defp error_text({:error, 5}),
    do: "Homing isn't enabled on this controller ($22). Unlock to jog from here."

  defp error_text({:error, code}), do: "The controller rejected the last command (error #{code})."
end
