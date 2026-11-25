defmodule CNCWeb.MachineLive do
  @moduledoc """
  The machine screen: bed view, position readout, and jog controls.

  Renders only what `CNC.Machine` reports. Keyboard jogging lives in the
  `JogKeys` hook; the bed is drawn by the `BedView` hook from `"pos"` events.
  """
  use CNCWeb, :live_view

  alias CNC.{Machine, Program}
  alias CNC.Machine.State

  @tiers CNCWeb.Jog.tiers()
  @steps [0.1, 1, 10, 50]
  @console_rows 200
  @mdi_rows 60

  @modes [
    {:jog, "Jog", "Jog: hold the stick or arrow keys to move"},
    {:inc, "Inc", "Incremental: one press, one step"},
    {:auto, "Auto", "Auto: open and run a program"},
    {:mdi, "MDI", "Manual data input: type commands for the controller"}
  ]
  @fade_ms 8_000

  @impl true
  def mount(_params, session, socket) do
    cnc = CNCWeb.Instance.from_session(session)

    # (The shell, CNCWeb.Shell, subscribes to the machine.)
    if connected?(socket) do
      Program.subscribe(cnc.program_topic)
      CNC.Controllers.subscribe(cnc.controllers_topic)
      CNCApp.Settings.subscribe(cnc.db)
    end

    machine = Machine.status(cnc.machine)
    program = Program.current(cnc.program)
    controller = CNC.Controllers.active(cnc.controllers)

    {:ok,
     socket
     |> assign(cnc: cnc, machine: machine, controller: controller, tier: :normal, step: 10)
     |> assign(frame: :work, action_error: nil, control_mode: :joystick, step_axis: :x)
     # The panel's mode, as on a machine's operator panel: Jog (by hand) or
     # Program (the loaded file and the job)
     # (Program if a file is already loaded)
     |> assign(panel: if(program, do: :auto, else: :jog), console_sub?: false)
     |> assign(modes: @modes)
     |> stream_configure(:mdi, dom_id: &"mdi-#{&1.id}")
     |> stream(:mdi, [])
     |> assign(more?: false, dismissed: MapSet.new(), fades: %{})
     |> assign(file?: false, program: program, file_error: nil)
     |> assign(work_edit: nil, undo_zero: nil, start_check?: false, abort_check?: false)
     |> assign(dry_lift: nil, single_block?: false)
     |> assign(settings: CNCApp.Settings.all(cnc.db))
     |> assign(zoom: if(program, do: :file, else: :bed), view_mode: :top)
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

    socket =
      if machine.last_job != socket.assigns.machine.last_job,
        do: forget_note(socket, :job),
        else: socket

    # A job started: the panel shows it (Jog can't be used meanwhile)
    socket =
      if machine.job && !socket.assigns.machine.job,
        do: assign(socket, panel: :auto),
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

    socket = if program, do: assign(socket, panel: :auto), else: socket

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

  def handle_info({:app_settings, settings}, socket),
    do: {:noreply, assign(socket, settings: settings)}

  # Controller traffic: the full log for Diagnostics, the conversation (no
  # status polls) for MDI
  def handle_info({:machine_console, entry}, socket) do
    socket =
      if socket.assigns.details?,
        do: stream_insert(socket, :console, entry, limit: -@console_rows),
        else: socket

    socket =
      if socket.assigns.panel == :mdi and entry.kind != :poll,
        do: stream_insert(socket, :mdi, entry, limit: -@mdi_rows),
        else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("jog", %{"x" => x, "y" => y, "tier" => tier} = params, socket) do
    with {:ok, vector} <- CNCWeb.Jog.analog_vector(x, y, params["z"] || 0),
         {:ok, tier} <- CNCWeb.Jog.tier(tier) do
      Machine.jog(srv(socket), vector, tier)
    end

    {:noreply, socket}
  end

  def handle_event("jog_heartbeat", _, socket), do: tap_noreply(socket, &Machine.jog_heartbeat/1)
  def handle_event("jog_stop", _, socket), do: tap_noreply(socket, &Machine.jog_stop/1)

  # Esc: stop jogging and hold.
  # Esc (the JogKeys hook): the same as the Hold button
  def handle_event("hold", _, socket) do
    Machine.jog_stop(srv(socket))
    Machine.feed_hold(srv(socket))
    {:noreply, socket}
  end

  def handle_event("unlock", _, socket), do: tap_noreply(socket, &Machine.unlock/1)
  def handle_event("home", _, socket), do: tap_noreply(socket, &Machine.home/1)
  def handle_event("resume", _, socket), do: tap_noreply(socket, &Machine.resume/1)

  # Cycle start: Resume a hold, or (Ready, a file loaded) the pre-start check.
  def handle_event("cycle_start", _, socket) do
    case cycle(socket.assigns.machine, socket.assigns.program) do
      :resume ->
        tap_noreply(socket, &Machine.resume/1)

      :next ->
        tap_noreply(socket, &Machine.resume/1)

      :start ->
        # Every run starts as a plain one: dry run and single block are chosen each time
        Machine.single_block(srv(socket), false)
        {:noreply, assign(socket, start_check?: true, dry_lift: nil, single_block?: false)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_start", _, socket), do: {:noreply, assign(socket, start_check?: false)}

  # Single block: for the next run (dialog) or this one (job panel)
  def handle_event("single_block", %{"on" => on}, socket) when on in ~w(true false) do
    on? = on == "true"
    Machine.single_block(srv(socket), on?)
    {:noreply, assign(socket, single_block?: on?)}
  end

  def handle_event("dry_lift", %{"mm" => mm}, socket) do
    lift = if mm in ~w(5 10 25), do: String.to_integer(mm), else: nil
    {:noreply, assign(socket, dry_lift: lift)}
  end

  def handle_event("confirm_start", _, socket) do
    %Program{name: name, text: text} = socket.assigns.program
    mode = if lift = socket.assigns.dry_lift, do: {:dry, lift}, else: :run

    case Machine.run(srv(socket), name, text, mode) do
      :ok ->
        {:noreply, assign(socket, start_check?: false)}

      {:error, reason} ->
        {:noreply, socket |> assign(start_check?: false) |> set_action_error(run_error(reason))}
    end
  end

  # Outline: trace the file's cutting area at a safe height (on the stock)
  def handle_event("outline", _, socket) do
    %Program{gcode: g} = socket.assigns.program
    {{x0, x1}, {y0, y1}, _} = g.cut_bounds || g.bounds

    error =
      case Machine.outline(srv(socket), {{x0, x1}, {y0, y1}}) do
        :ok -> nil
        {:error, :outside_travel} -> "The outline would leave the travel from this work zero."
        {:error, :no_work_offset} -> "The controller hasn't reported a work zero yet."
        {:error, :moving} -> "Wait for the machine to stop, then Outline."
        {:error, {:invalid_state, _}} -> "Only when the machine is Ready."
        {:error, other} -> "Couldn't outline: #{inspect(other)}"
      end

    {:noreply, socket |> assign(start_check?: false) |> set_action_error(error)}
  end

  # Check: the controller reads every line without moving (check mode)
  def handle_event("confirm_check", _, socket) do
    %Program{name: name, text: text} = socket.assigns.program

    case Machine.check(srv(socket), name, text) do
      :ok ->
        {:noreply, assign(socket, start_check?: false)}

      {:error, reason} ->
        {:noreply, socket |> assign(start_check?: false) |> set_action_error(run_error(reason))}
    end
  end

  def handle_event("abort_job", _, socket), do: {:noreply, assign(socket, abort_check?: true)}
  def handle_event("cancel_abort", _, socket), do: {:noreply, assign(socket, abort_check?: false)}

  def handle_event("confirm_abort", _, socket) do
    Machine.abort(srv(socket))
    {:noreply, assign(socket, abort_check?: false)}
  end

  def handle_event("feed_override", %{"op" => op}, socket)
      when op in ~w(reset plus10 minus10) do
    Machine.feed_override(srv(socket), String.to_existing_atom(op))
    {:noreply, socket}
  end

  def handle_event("rapid_override", %{"percent" => p}, socket) when p in ~w(100 50 25) do
    Machine.rapid_override(srv(socket), String.to_integer(p))
    {:noreply, socket}
  end

  def handle_event("dismiss", %{"note" => "job"}, socket),
    do: {:noreply, dismiss(socket, :job)}

  def handle_event("reset", _, socket), do: tap_noreply(socket, &Machine.reset/1)

  def handle_event("step", %{"x" => x, "y" => y} = params, socket) do
    with {:ok, vector} when vector != {0, 0, 0} <- vector(x, y, params["z"] || 0),
         do: Machine.jog_step(srv(socket), vector, socket.assigns.step)

    {:noreply, socket}
  end

  def handle_event("tier", %{"tier" => tier}, socket) do
    case CNCWeb.Jog.tier(tier) do
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

  # The bed view in 2D (top down, with the speed meters) or 3D.
  def handle_event("view_mode", %{"mode" => mode}, socket) when mode in ["top", "3d"],
    do: {:noreply, assign(socket, view_mode: String.to_existing_atom(mode))}

  # A view that just appeared asks for what there is now.
  def handle_event("viewport_ready", _, socket),
    do: {:noreply, socket |> push_program() |> push_pos(socket.assigns.machine)}

  def handle_event("zoom", %{"zoom" => zoom}, socket) when zoom in ~w(bed file) do
    zoom = String.to_existing_atom(zoom)
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

  def handle_event("undo_zero", _, socket) do
    %{axes: axes, wco: wco} = socket.assigns.undo_zero
    values = for a <- axes, do: {a, elem(wco, Enum.find_index([:x, :y, :z], &(&1 == a)))}

    case Machine.set_work_offset(srv(socket), values) do
      :ok -> {:noreply, assign(socket, undo_zero: nil)}
      _ -> {:noreply, set_action_error(socket, "Couldn't undo: wait for the machine to stop.")}
    end
  end

  def handle_event("dismiss", %{"note" => "undo"}, socket),
    do: {:noreply, assign(socket, undo_zero: nil)}

  def handle_event("dismiss", %{"note" => "action"}, socket),
    do: {:noreply, dismiss(socket, :action)}

  def handle_event("dismiss", %{"note" => "travel"}, socket),
    do: {:noreply, dismiss(socket, :travel)}

  def handle_event("panel", %{"mode" => mode}, socket) when mode in ~w(jog inc auto mdi) do
    panel = String.to_existing_atom(mode)
    control = if panel == :inc, do: :step, else: :joystick
    {:noreply, socket |> assign(panel: panel, control_mode: control) |> sync_console()}
  end

  def handle_event("control_mode", %{"mode" => mode}, socket) when mode in ~w(joystick step),
    do: {:noreply, assign(socket, control_mode: String.to_existing_atom(mode))}

  def handle_event("step_axis", %{"axis" => axis}, socket) when axis in ~w(x y z),
    do: {:noreply, assign(socket, step_axis: String.to_existing_atom(axis))}

  def handle_event("frame", %{"frame" => frame}, socket) when frame in ~w(work machine),
    do: {:noreply, assign(socket, frame: String.to_existing_atom(frame))}

  def handle_event("zero", %{"axes" => axes}, socket) do
    axes = for c <- String.graphemes(axes), c in ~w(x y z), do: String.to_existing_atom(c)
    # Remember where the zero was, so a mistaken tap can be undone: zeroing
    # replaces the setup you just touched off.
    before = socket.assigns.machine.wco

    socket =
      if axes != [] and Machine.set_work_zero(srv(socket), axes) == :ok and before,
        do: assign(socket, undo_zero: %{axes: axes, wco: before}),
        else: socket

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

  # Diagnostics (view only): the full traffic log, docked under the map
  def handle_event("toggle_details", _, %{assigns: %{details?: false}} = socket) do
    {:noreply,
     socket
     |> assign(details?: true)
     |> sync_console()
     |> stream(:console, Machine.console(srv(socket)), reset: true)}
  end

  def handle_event("toggle_details", _, socket) do
    Machine.unsubscribe_polls(socket.assigns.cnc.topic)

    {:noreply,
     socket
     |> assign(details?: false, polls?: false)
     |> sync_console()
     |> stream(:console, [], reset: true)}
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
    <Layouts.app flash={@flash} current={:machine} machine={@shell_machine}>
      <div id="jog-keys" phx-hook="JogKeys" data-tier={@tier} hidden></div>

      <%!-- One structure, two layouts (assets/css/app.css):
           touch and small screens get the controller (readout, map, controller,
           Hold dock); a wide screen with a mouse gets the workstation (map,
           readout and jog panel, details, docked console, Hold in the bar). --%>
      <div class={["cnc", @details? && "has-console"]} data-mode={@control_mode}>
        <%!-- The file input, always on the page: the file dialog's drop zone,
             the map and the Program panel all feed it --%>
        <form id="upload-form" class="cnc-sr-only" phx-change="validate_upload" phx-submit="upload">
          <.live_file_input upload={@uploads.gcode} />
        </form>
        <header class="cnc-bar">
          <%!-- Coded by icon and words as well as colour (ISA-101): calm when
               normal, coloured when the machine needs attention. --%>
          <div
            class={"cnc-state cnc-state--#{state_class(@machine)}"}
            role="status"
            id="machine-state"
          >
            <.icon name={state_icon(@machine)} class="cnc-state-icon" />
            <span>{state_label(@machine)}</span>
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
          <%!-- Grouped as on a machine's operator panel: the job, then Reset
               (abandons it; quiet, apart), then Resume and Hold side by side,
               Hold last and always in the same place. --%>
          <%!-- The cycle group, as on a machine's panel: Reset (Abort while a
               job runs), Cycle Start / Resume, Hold, always in this place.
               Diagnostics, a view, sits apart. --%>
          <div class="cnc-actions">
            <UI.button
              id="diagnostics-toggle"
              variant="quiet"
              phx-click="toggle_details"
              aria-pressed={to_string(@details?)}
              aria-controls="diagnostics"
              title="The traffic to and from the controller (view only)"
            >
              <.icon name="hero-command-line" class="ui-btn-icon" /> Diagnostics
            </UI.button>
            <div class="cnc-run-group" role="group" aria-label="Cycle">
              <UI.button
                id="bar-reset"
                variant="quiet"
                class="cnc-reset"
                phx-click={if @machine.job, do: "abort_job", else: "reset"}
                disabled={!@machine.connected?}
                title={
                  if @machine.job,
                    do: "End the job: stops at once and comes back locked (asks first)",
                    else: "Soft reset: stops and clears the controller; it comes back locked"
                }
              >
                {if @machine.job, do: "Abort", else: "Reset"}
              </UI.button>
              <%!-- Cycle start, as on a machine's panel: Start the loaded file
                   when Ready, Resume a hold. Same place and size either way. --%>
              <UI.button
                id="bar-resume"
                class="cnc-cycle"
                phx-click="cycle_start"
                disabled={cycle(@machine, @program) == nil}
                title={
                  if held?(@machine),
                    do: "Carry on after a Hold",
                    else: "Run the loaded file (checks first)"
                }
              >
                <.icon name="hero-play" class="ui-btn-icon" />
                {cond do
                  held?(@machine) -> "Resume"
                  cycle(@machine, @program) == :next -> "Next line"
                  true -> "Start"
                end}
              </UI.button>
              <UI.hold_button id="bar-hold" />
            </div>
          </div>
        </header>

        <%!-- The message line: always there, one message at a time, the
             most important first (as listed); "+N" when more are waiting.
             It never covers anything and never pushes anything. --%>
        <div class="cnc-messages" id="messages">
          <p :if={@controller == nil and @machine.adapter == nil} class="cnc-note" id="no-controller">
            No controller chosen.
            <.link navigate={~p"/controllers"} class="cnc-meta-link">Add or pick one</.link>
            to connect.
          </p>
          <div :if={@machine.state == :alarm} class="cnc-lock" role="alert">
            <span class="cnc-lock-tag">Locked</span>
            <p title={lock_text(@machine)}>
              {lock_text(@machine)}
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
          <div
            :if={held?(@machine) and @machine.state == :running}
            class="cnc-note cnc-note--warn"
            id="note-held"
          >
            <p>
              On hold: motion paused, the position kept. The spindle keeps turning.
              Resume to carry on, or end the job.
            </p>
            <button type="button" id="held-abort" class="cnc-btn cnc-abort" phx-click="abort_job">
              Abort the job
            </button>
          </div>
          <div
            :if={@machine.state == :running and match?(%{waiting?: true}, @machine.job)}
            class="cnc-note"
            id="note-single"
          >
            <p>
              Single block: line {elem(@machine.job.next, 0)} is next ({elem(@machine.job.next, 1)}).
              Press Next line for it, or turn single block off to run on.
            </p>
          </div>
          <.note
            :if={
              @machine.last_job && not MapSet.member?(@dismissed, :job) &&
                not (@machine.state == :alarm and @machine.last_job.result == :checked)
            }
            id="note-job"
            key="job"
            warn={@machine.last_job.result != :done}
          >
            {job_outcome(@machine.last_job)}
          </.note>
          <.note
            :if={note = not MapSet.member?(@dismissed, :error) && error_text(@machine.last_error)}
            id="note-error"
            key="error"
          >
            {note}
          </.note>
          <.note :if={@action_error} id="note-action" key="action">{@action_error}</.note>
          <.note :if={@undo_zero} id="note-undo-zero" key="undo">
            Zeroed {@undo_zero.axes |> Enum.map(&String.upcase(to_string(&1))) |> Enum.join("/")}.
            <button type="button" id="undo-zero" class="cnc-link" phx-click="undo_zero">
              Undo
            </button>
            to put the work zero back where it was.
          </.note>
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

        <section
          class="cnc-view"
          aria-label="Bed and Z"
          id="map"
          phx-drop-target={@uploads.gcode.ref}
        >
          <%!-- The map's own controls in a strip above it, so they never
               cover what it shows (the speed gauges, the Z scale) --%>
          <div class="cnc-view-bar">
            <div class="cnc-view-switch ui-actions" role="group" aria-label="View">
              <UI.button
                :for={{mode, label} <- [top: "2D", "3d": "3D"]}
                size="sm"
                variant={if @view_mode == mode, do: "primary", else: "secondary"}
                id={"view-#{mode}"}
                phx-click="view_mode"
                phx-value-mode={mode}
                aria-pressed={to_string(@view_mode == mode)}
              >
                {label}
              </UI.button>
            </div>
            <span class="cnc-view-bar-gap"></span>
            <%!-- Always there, same size: no shift when a file loads or the
                 zoom changes (in 3D the viewport has its own views) --%>
            <UI.viewport_views :if={@view_mode == :"3d"} for="viewport" />
            <div
              :if={@view_mode == :top}
              id="zoom-toggle"
              class="cnc-seg cnc-seg--small cnc-zoom-seg"
              role="group"
              aria-label="Zoom"
            >
              <button
                :for={{z, label} <- [bed: "Bed", file: "File"]}
                type="button"
                class="cnc-btn"
                id={"zoom-#{z}"}
                phx-click="zoom"
                phx-value-zoom={z}
                aria-pressed={to_string(@zoom == z)}
                disabled={z == :file and @program == nil}
              >
                {label}
              </button>
            </div>
          </div>
          <UI.viewport
            :if={@view_mode == :"3d"}
            id="viewport"
            travel={travel_json(@machine.travel)}
            class="cnc-bed"
            views={false}
            trail={@settings.jog_trail}
          />
          <div
            :if={@view_mode == :top}
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
            data-trail={to_string(@settings.jog_trail)}
          >
            <canvas
              role="img"
              aria-label="Top-down view of the bed with the tool position, Z height, and X/Y and Z speed"
            >
            </canvas>
          </div>
        </section>

        <%!-- The right column: readout, jog, details. Full height beside the
             map and the console, which docks under the map only (as an IDE's
             bottom panel), so opening it never moves these. --%>
        <div class="cnc-right">
          <section class="cnc-dro" aria-label="Position">
            <div class="cnc-dro-head">
              <h2 class="cnc-h">
                {if frame(@machine, @frame) == :work, do: "Work", else: "Machine"} position
                <span class="cnc-unit">mm</span>
              </h2>
              <.frame_switch machine={@machine} frame={@frame} />
            </div>
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
              <%!-- Moves the machine, unlike the zeroing beside it: set apart,
                 with a motion icon --%>
              <button
                type="button"
                id="go-to-zero"
                class="cnc-btn cnc-btn--motion"
                phx-click="go_to_zero"
                disabled={not can_go_to_zero?(@machine)}
                title="Moves the machine: rapid to X0 Y0 at a safe height"
              >
                <.icon name="hero-arrow-down-left" class="ui-btn-icon" /> Go to X0 Y0
              </button>
            </div>
          </section>

          <%!-- The operator panel's modes, as on a Fanuc/Haas mode selector:
               JOG (continuous), INC (incremental, a step a press), AUTO (run
               the program), MDI (type commands). --%>
          <section class="cnc-ctl" aria-label="Operating mode">
            <div class="cnc-seg cnc-modes" role="group" aria-label="Mode">
              <button
                :for={{mode, label, title} <- @modes}
                type="button"
                class="cnc-btn"
                id={"panel-#{mode}"}
                aria-pressed={to_string(@panel == mode)}
                phx-click="panel"
                phx-value-mode={mode}
                title={title}
              >
                {label}
              </button>
            </div>
            <%!-- One fixed height for both modes: switching never moves what's below --%>
            <div class="cnc-mode-body">
              <%= if @panel in [:jog, :inc] do %>
                <p :if={@machine.state == :running} class="cnc-mode-off" id="jog-off">
                  Jogging is off while a job runs.
                </p>
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
                </div>
              <% else %>
                <%= if @panel == :auto do %>
                  <.program_panel
                    program={@program}
                    machine={@machine}
                    uploads={@uploads}
                    file_error={@file_error}
                  />
                <% else %>
                  <.mdi_panel
                    streams={@streams}
                    machine={@machine}
                    commands?={@commands?}
                    command_help={@command_help}
                    raw_error={@raw_error}
                  />
                <% end %>
              <% end %>
            </div>
          </section>

          <%!-- Workstation only: details and keyboard --%>
          <aside class="cnc-side" aria-label="Details and keyboard">
            <h2 class="cnc-h">Controller</h2>
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
            <button
              :if={@settings.jog_trail}
              type="button"
              class="cnc-btn cnc-btn--quiet"
              phx-click={
                if(@view_mode == :top,
                  do: JS.dispatch("bed:clear-trail", to: "#bed"),
                  else: JS.dispatch("viewport:clear-trail", to: "#viewport")
                )
              }
            >
              Clear trail
            </button>
          </aside>
        </div>

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
            <div class="cnc-row cnc-dialog-actions">
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
            <div id="upload-zone">
              <label
                class="cnc-drop"
                for={@uploads.gcode.ref}
                phx-drop-target={@uploads.gcode.ref}
              >
                <span class="cnc-drop-main">Choose a file</span>
                <span class="cnc-sub">
                  or drop it here, or on the map. .nc, .gcode, .ngc, .tap; up to 20 MB.
                </span>
              </label>
              <.upload_status uploads={@uploads} file_error={@file_error} />
            </div>
            <.program_summary :if={@program} program={@program} fit={fit(@program, @machine)} />
            <div class="cnc-row cnc-dialog-actions">
              <button :if={@program} type="button" class="cnc-btn" phx-click="clear_program">
                Clear file
              </button>
              <button type="button" class="cnc-btn cnc-btn--primary" phx-click="close_file">
                {if @program, do: "Show on the map", else: "Close"}
              </button>
            </div>
          </div>
        </div>

        <%!-- Diagnostics: the traffic to and from the controller, view only
             (type commands in MDI). Docked under the map. --%>
        <section
          :if={@details?}
          id="diagnostics"
          class="cnc-console"
          aria-label="Diagnostics: controller traffic"
        >
          <div class="cnc-console-bar">
            <h2 class="cnc-h">Diagnostics</h2>
            <label class="cnc-check">
              <input type="checkbox" checked={@polls?} phx-click="toggle_polls" />
              <span>Show status polls</span>
            </label>
            <button type="button" class="cnc-btn cnc-btn--quiet" phx-click="clear_console">
              Clear
            </button>
            <button type="button" class="cnc-btn cnc-btn--quiet" phx-click="toggle_details">
              Close
            </button>
          </div>
          <ol id="diagnostics-log" class="cnc-log" phx-update="stream" phx-hook="ConsoleScroll">
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
        </section>
      </div>

      <UI.dialog
        :if={@start_check? and @program}
        id="start-dialog"
        title={"Start #{@program.name}?"}
        on_cancel="cancel_start"
      >
        <.start_checks
          program={@program}
          machine={@machine}
          fit={fit(@program, @machine, @dry_lift || 0)}
        />
        <div class="cnc-job-ov" id="start-rapids">
          <span class="cnc-h">Rapids</span>
          <.rapid_seg machine={@machine} id="start-rapid" />
        </div>
        <div class="cnc-job-ov" id="start-dry">
          <span class="cnc-h">Dry run</span>
          <div class="cnc-seg cnc-seg--small" role="group" aria-label="Dry run: Z lifted by">
            <button
              :for={{mm, label} <- [{nil, "Off"}, {5, "Z +5"}, {10, "Z +10"}, {25, "Z +25"}]}
              type="button"
              class="cnc-btn num"
              id={"dry-#{mm || "off"}"}
              phx-click="dry_lift"
              phx-value-mm={mm || "off"}
              aria-pressed={to_string(@dry_lift == mm)}
            >
              {label}
            </button>
          </div>
        </div>
        <div class="cnc-job-ov" id="start-single">
          <span class="cnc-h">Single block</span>
          <.single_block_seg on?={@single_block?} id="start-single" />
        </div>
        <p class="cnc-sub">
          A new program's first run is usually a dry run (Z lifted above the stock,
          spindle off), then the first cut at 25% rapids, in single block.
        </p>
        <%!-- In the order a new program is proved: check it, see where it
             lands, then cut. The main action last, as on macOS and the web. --%>
        <:actions>
          <UI.button variant="quiet" id="cancel-start" phx-click="cancel_start">Not yet</UI.button>
          <UI.button
            id="check-start"
            phx-click="confirm_check"
            title="The controller reads every line without moving and lists any it refuses"
          >
            <.icon name="hero-magnifying-glass" class="ui-btn-icon" /> Check first
          </UI.button>
          <UI.button
            id="outline-start"
            phx-click="outline"
            disabled={@program.gcode.bounds == nil}
            title="Trace the file's area at a safe height, to see where it lands on the stock"
          >
            <.icon name="hero-square-2-stack" class="ui-btn-icon" /> Outline
          </UI.button>
          <UI.button
            variant="primary"
            id="confirm-start"
            phx-click="confirm_start"
            disabled={fit(@program, @machine, @dry_lift || 0) != []}
          >
            <.icon name="hero-play" class="ui-btn-icon" />
            {if @dry_lift, do: "Start dry run", else: "Start cutting"}
          </UI.button>
        </:actions>
      </UI.dialog>

      <UI.dialog
        :if={@abort_check? and @machine.job}
        id="abort-dialog"
        title="Abort the job?"
        on_cancel="cancel_abort"
      >
        <p class="ui-muted">
          The machine stops at once (a soft reset) and comes back locked: unlock or
          home to carry on. The work zero is kept. The job can't continue from here.
        </p>
        <:actions>
          <UI.button id="cancel-abort" phx-click="cancel_abort">Keep running</UI.button>
          <UI.button variant="danger" id="confirm-abort" phx-click="confirm_abort">
            Abort
          </UI.button>
        </:actions>
      </UI.dialog>
    </Layouts.app>
    """
  end

  attr :streams, :any, required: true
  attr :machine, State, required: true
  attr :commands?, :boolean, required: true
  attr :command_help, :list, required: true
  attr :raw_error, :any, required: true

  # MDI (manual data input): type a command for the controller; its replies
  # just above. Off while a job runs (the state machine refuses it anyway).
  defp mdi_panel(assigns) do
    ~H"""
    <div class="cnc-mdi" id="mdi">
      <p :if={@machine.state == :running} class="cnc-mode-off" id="mdi-off">
        MDI is off while a job runs.
      </p>
      <%!-- The log stays on the page while the reference shows (hidden), so
           replies arriving meanwhile aren't lost --%>
      <div :if={@commands?} id="console-help" class="cnc-help cnc-mdi-help">
        <p class="cnc-help-lead">
          Click a command to put it in the input; nothing is sent until you press Enter.
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
                    JS.dispatch("console:insert", to: "#mdi-input", detail: %{text: item.cmd})
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
      <ol
        id="mdi-log"
        class="cnc-log cnc-mdi-log"
        phx-update="stream"
        phx-hook="ConsoleScroll"
        hidden={@commands?}
      >
        <li
          :for={{dom_id, entry} <- @streams.mdi}
          id={dom_id}
          class={["cnc-log-row", "is-#{entry.dir}", tone(entry)]}
        >
          <span class="cnc-log-dir">{if entry.dir == :out, do: "→", else: "←"}</span>
          <span class="cnc-log-text">{entry.text}</span>
        </li>
      </ol>
      <form
        id="mdi-input"
        class="cnc-term"
        phx-submit="send_raw"
        phx-hook="ConsoleInput"
        autocomplete="off"
      >
        <label for="mdi-line" class="cnc-term-prompt" title="Manual data input">MDI</label>
        <input
          id="mdi-line"
          name="line"
          type="text"
          spellcheck="false"
          autocapitalize="off"
          placeholder="A command, e.g. $$ or G0 X10"
          aria-describedby="mdi-hint"
          disabled={@machine.state == :running}
        />
        <button type="submit" class="cnc-btn" disabled={@machine.state == :running}>Send</button>
      </form>
      <div class="cnc-mdi-foot">
        <p id="mdi-hint" class={["cnc-term-hint", @raw_error && "is-error"]}>
          {@raw_error || "Typed moves skip the jog safety stop and the travel limit. ↑ ↓ recall."}
        </p>
        <button
          type="button"
          class="cnc-btn cnc-btn--quiet"
          phx-click="toggle_commands"
          aria-expanded={to_string(@commands?)}
          aria-controls="console-help"
        >
          {if @commands?, do: "Hide commands", else: "Commands"}
        </button>
      </div>
    </div>
    """
  end

  attr :program, :any, required: true
  attr :machine, State, required: true
  attr :uploads, :any, required: true
  attr :file_error, :any, required: true

  # Program mode: the job while one runs; else the loaded file and Start;
  # else an invitation to load one.
  defp program_panel(assigns) do
    ~H"""
    <div class="cnc-program" id="program-panel">
      <%= cond do %>
        <% @machine.job -> %>
          <.job_panel job={@machine.job} program={@program} machine={@machine} />
        <% @program -> %>
          <section class="cnc-file-side" aria-label="Loaded file">
            <.program_summary program={@program} fit={fit(@program, @machine)} />
            <div class="cnc-row">
              <UI.button
                variant="primary"
                id="program-start"
                phx-click="cycle_start"
                disabled={cycle(@machine, @program) != :start}
              >
                <.icon name="hero-play" class="ui-btn-icon" /> Start…
              </UI.button>
              <UI.button variant="quiet" id="open-file" phx-click="open_file">Open another</UI.button>
              <UI.button variant="quiet" id="program-clear" phx-click="clear_program">
                Clear
              </UI.button>
            </div>
          </section>
        <% true -> %>
          <div class="cnc-program-empty" id="program-empty">
            <.icon name="hero-document-arrow-up" class="cnc-program-empty-icon" />
            <p>No file loaded.</p>
            <UI.button id="open-file" phx-click="open_file">Open file</UI.button>
            <p class="cnc-sub">or drop a G-code file on the map</p>
          </div>
      <% end %>
      <.upload_status uploads={@uploads} file_error={@file_error} />
    </div>
    """
  end

  attr :uploads, :any, required: true
  attr :file_error, :any, required: true

  defp upload_status(assigns) do
    ~H"""
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
    <p :for={err <- upload_errors(@uploads.gcode)} class="cnc-set-error">{upload_error(err)}</p>
    <p :if={@file_error} class="cnc-set-error">{@file_error}</p>
    """
  end

  attr :program, Program, required: true
  attr :machine, State, required: true
  attr :fit, :any, required: true

  # Before anything moves: where it starts, whether it fits, which bit, and
  # what only the operator can check.
  defp start_checks(assigns) do
    ~H"""
    <ul class="cnc-checks" id="start-checks">
      <li class={["cnc-check-item", @fit == [] && "is-ok", @fit != [] && "is-bad"]}>
        <.icon
          name={if(@fit == [], do: "hero-check-circle", else: "hero-x-circle")}
          class="cnc-check-icon"
        />
        <span>
          <%= cond do %>
            <% @fit == [] -> %>
              Fits the travel from the work zero (X {fmt(elem(@machine.wco, 0))}, Y {fmt(
                elem(@machine.wco, 1)
              )}, Z {fmt(elem(@machine.wco, 2))} on the machine).
            <% @fit == :no_work_zero -> %>
              The controller hasn't reported a work zero yet.
            <% true -> %>
              Won't fit from this work zero: {Enum.map_join(@fit, "; ", &fit_issue/1)}
          <% end %>
        </span>
      </li>
      <li class="cnc-check-item">
        <.icon name="hero-wrench" class="cnc-check-icon" />
        <span>
          {case Enum.reject(@program.gcode.tools, &is_nil/1) do
            [] ->
              "The file doesn't name a bit: check the one that's in."

            tools ->
              "Bit: " <> Enum.map_join(tools, ", ", &"T#{&1}") <> ". Tool changes aren't handled yet."
          end}
        </span>
      </li>
      <li class="cnc-check-item">
        <.icon name="hero-hand-raised" class="cnc-check-icon" />
        <span>Stock clamped, spindle on and up to speed, hands and cables clear.</span>
      </li>
    </ul>
    """
  end

  attr :job, :map, required: true
  attr :program, :any, required: true
  attr :machine, State, required: true

  # The running job: how far, how long, the feed override, Abort.
  defp job_panel(assigns) do
    fraction = job_fraction(assigns.job, assigns.machine)
    elapsed = DateTime.diff(DateTime.utc_now(), assigns.job.started_at)
    {feed_ov, _, _} = assigns.machine.overrides || {100, 100, 100}

    assigns =
      assign(assigns,
        pct: round(fraction * 100),
        elapsed: elapsed,
        left: time_left(fraction, elapsed, assigns.program, feed_ov),
        feed_ov: feed_ov
      )

    ~H"""
    <section class="cnc-job" id="job-panel" aria-label="Job">
      <div class="cnc-job-head">
        <p class="cnc-file-name">
          {@job.name}
          <span :if={@job.mode == :check} class="cnc-sub-inline" id="job-mode">
            Check run: the controller reads every line, nothing moves
          </span>
          <span :if={match?({:dry, _}, @job.mode)} class="cnc-sub-inline cnc-dry" id="job-mode">
            Dry run: Z lifted {elem(@job.mode, 1)} mm, spindle left off
          </span>
        </p>
        <span class="cnc-job-pct num">{@pct}%</span>
      </div>
      <div
        class="cnc-job-bar"
        role="progressbar"
        aria-valuemin="0"
        aria-valuemax="100"
        aria-valuenow={@pct}
        aria-label="Progress"
      >
        <span style={"width: #{@pct}%"}></span>
      </div>
      <dl class="cnc-facts">
        <dt>sent to</dt>
        <dd class="num">
          line {@job.line} of {(@program && @program.gcode.lines) || @job.total}
        </dd>
        <dt>elapsed</dt>
        <dd class="num">{duration(@elapsed)}</dd>
        <dt>left</dt>
        <dd class="num">{if @left, do: "about #{duration(@left)}", else: "–"}</dd>
      </dl>
      <div :if={@job.mode != :check} class="cnc-job-ov">
        <span class="cnc-h">Feed</span>
        <div class="cnc-seg cnc-seg--small" role="group" aria-label="Feed override">
          <button
            type="button"
            class="cnc-btn"
            id="ov-minus"
            phx-click="feed_override"
            phx-value-op="minus10"
          >
            −10%
          </button>
          <button
            type="button"
            class="cnc-btn num"
            id="ov-reset"
            phx-click="feed_override"
            phx-value-op="reset"
            aria-pressed={to_string(@feed_ov == 100)}
            title="Back to 100%"
          >
            {@feed_ov}%
          </button>
          <button
            type="button"
            class="cnc-btn"
            id="ov-plus"
            phx-click="feed_override"
            phx-value-op="plus10"
          >
            +10%
          </button>
        </div>
      </div>
      <div :if={@job.mode != :check} class="cnc-job-ov">
        <span class="cnc-h">Rapids</span>
        <.rapid_seg machine={@machine} id="job-rapid" />
      </div>
      <div :if={@job.mode != :check} class="cnc-job-ov">
        <span class="cnc-h">Single block</span>
        <.single_block_seg on?={@job.single_block?} id="job-single" />
      </div>
      <button
        type="button"
        id="abort-job"
        class="cnc-btn cnc-btn--quiet cnc-abort"
        phx-click="abort_job"
      >
        Abort the job
      </button>
    </section>
    """
  end

  attr :on?, :boolean, required: true
  attr :id, :string, required: true

  defp single_block_seg(assigns) do
    ~H"""
    <div class="cnc-seg cnc-seg--small" role="group" aria-label="Single block">
      <button
        :for={{on?, label} <- [{false, "Off"}, {true, "On"}]}
        type="button"
        class="cnc-btn"
        id={"#{@id}-#{if on?, do: "on", else: "off"}"}
        phx-click="single_block"
        phx-value-on={to_string(on?)}
        aria-pressed={to_string(@on? == on?)}
      >
        {label}
      </button>
    </div>
    """
  end

  attr :machine, State, required: true
  attr :id, :string, required: true

  # Rapid override: 25 / 50 / 100%, showing what the controller reports
  defp rapid_seg(assigns) do
    assigns = assign(assigns, :current, elem(assigns.machine.overrides || {100, 100, 100}, 1))

    ~H"""
    <div class="cnc-seg cnc-seg--small" role="group" aria-label="Rapid override">
      <button
        :for={p <- [25, 50, 100]}
        type="button"
        class="cnc-btn num"
        id={"#{@id}-#{p}"}
        phx-click="rapid_override"
        phx-value-percent={p}
        aria-pressed={to_string(@current == p)}
        disabled={not @machine.connected?}
      >
        {p}%
      </button>
    </div>
    """
  end

  # How much has actually run: the controller accepts lines into its
  # planner well ahead of the tool, so the lines acked minus the moves still
  # waiting there (its status: Bf, planner blocks free) estimate what's
  # been done. On a short file the planner can hold most of it.
  @planner_blocks 15
  defp job_fraction(%{total: total}, _machine) when total == 0, do: 0.0

  defp job_fraction(job, %State{buffer: buffer}) do
    waiting =
      case buffer do
        {free, _} when is_integer(free) -> max(@planner_blocks - free, 0)
        _ -> 0
      end

    min(max(job.acked - waiting, 0) / job.total, 1.0)
  end

  # Early on, from the file's estimate (at the feed override); once a few
  # percent are done, from the pace so far.
  defp time_left(fraction, _elapsed, %Program{gcode: %{seconds: secs}}, ov) when fraction < 0.05,
    do: round(secs * (1 - fraction) * 100 / max(ov, 10))

  defp time_left(fraction, elapsed, _program, _ov) when fraction > 0 and fraction < 1,
    do: round(elapsed / fraction - elapsed)

  defp time_left(_, _, _, _), do: nil

  defp duration(seconds) when is_integer(seconds) and seconds >= 3600,
    do: "#{div(seconds, 3600)}:#{pad(div(rem(seconds, 3600), 60))}:#{pad(rem(seconds, 60))}"

  defp duration(seconds) when is_integer(seconds),
    do: "#{div(max(seconds, 0), 60)}:#{pad(rem(max(seconds, 0), 60))}"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp job_outcome(%{result: :checked} = j), do: check_summary(j)

  defp job_outcome(%{result: :done, mode: {:dry, mm}} = j),
    do:
      "Dry run of #{j.name} (Z +#{mm} mm) finished in #{duration(DateTime.diff(j.ended_at, j.started_at))}."

  defp job_outcome(%{result: :done} = j),
    do: "Finished #{j.name} in #{duration(DateTime.diff(j.ended_at, j.started_at))}."

  defp job_outcome(%{result: :aborted} = j), do: "Aborted #{j.name} at line #{j.line}."

  defp job_outcome(%{result: :error, error: {code, line, text}} = j),
    do: "#{j.name} stopped: the controller refused line #{line} (#{text}), error #{code}."

  defp job_outcome(%{result: {:alarm, code}} = j),
    do: "#{j.name} stopped at line #{j.line}: alarm #{code}. #{alarm_cause(code)}"

  defp job_outcome(%{result: :lost} = j),
    do: "#{j.name} stopped at line #{j.line}: the connection to the controller was lost."

  defp job_outcome(j), do: "#{j.name} stopped at line #{j.line}."

  # A check's result, for the message line
  defp check_summary(%{errors: [], total: n} = j),
    do: "Checked #{j.name}: the controller accepts all #{n} lines."

  defp check_summary(%{errors: errors} = j) do
    listed =
      errors
      |> Enum.take(3)
      |> Enum.map_join("; ", fn {code, line, text} ->
        "line #{line} (#{text}): #{refusal(code)}"
      end)

    more = if length(errors) > 3, do: " and #{length(errors) - 3} more", else: ""

    "Checked #{j.name}: #{length(errors)} #{if length(errors) == 1, do: "line", else: "lines"} refused: #{listed}#{more}."
  end

  # Grbl's error codes, as reasons
  defp refusal(1), do: "a value without its letter"
  defp refusal(2), do: "a badly formed number"
  defp refusal(9), do: "the machine is locked"
  defp refusal(15), do: "outside the travel"
  defp refusal(20), do: "a code this controller doesn't support"
  defp refusal(22), do: "no feed rate set"
  defp refusal(24), do: "two codes that can't go together"
  defp refusal(25), do: "a word given twice"
  defp refusal(33), do: "an arc that doesn't add up"
  defp refusal(code), do: "error #{code}"

  # The Locked banner: after a check it says how the check went (the
  # controller restarts after one, which is why it's locked).
  defp lock_text(%State{alarm: :reset, last_job: %{result: :checked} = j}),
    do: check_summary(j) <> " The controller restarts after a check: unlock to carry on."

  defp lock_text(%State{alarm: alarm}), do: alarm_text(alarm)

  defp run_error(:busy), do: "Wait for the machine to settle, then Start."
  defp run_error({:invalid_state, _}), do: "Only when the machine is Ready."
  defp run_error(:empty), do: "The file has nothing to run."
  defp run_error({:line_too_long, n}), do: "Line #{n} is too long for the controller."
  defp run_error(other), do: "Couldn't start: #{inspect(other)}"

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

  # Controller traffic is subscribed to only while Diagnostics or MDI is
  # showing; MDI starts with the recent conversation.
  defp sync_console(socket) do
    want? = socket.assigns.details? or socket.assigns.panel == :mdi
    topic = socket.assigns.cnc.topic

    socket =
      cond do
        want? and not socket.assigns.console_sub? ->
          Machine.subscribe_console(topic)
          assign(socket, console_sub?: true)

        not want? and socket.assigns.console_sub? ->
          Machine.unsubscribe_console(topic)
          assign(socket, console_sub?: false)

        true ->
          socket
      end

    if socket.assigns.panel == :mdi do
      recent =
        Machine.console(srv(socket)) |> Enum.reject(&(&1.kind == :poll)) |> Enum.take(-@mdi_rows)

      stream(socket, :mdi, recent, reset: true)
    else
      stream(socket, :mdi, [], reset: true)
    end
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
      speed: speed_payload(m, socket.assigns.tier),
      # The running job's key (its start), so the views can follow it
      job: m.job && DateTime.to_iso8601(m.job.started_at)
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
  # lift: a dry run's Z lift, which can take the program past the top
  defp fit(program, machine, lift \\ 0)
  defp fit(%Program{gcode: %{bounds: nil}}, _machine, _lift), do: []
  defp fit(_program, %State{wco: nil}, _lift), do: :no_work_zero

  defp fit(%Program{gcode: %{bounds: bounds}}, %State{wco: wco, travel: travel}, lift) do
    for {axis, i} <- [x: 0, y: 1, z: 2],
        {pmin, pmax} = elem(bounds, i),
        {tmin, tmax} = elem(travel, i),
        offset = elem(wco, i) + if(axis == :z, do: lift, else: 0),
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

  defp short_link(%{type: :fluidnc_sim}), do: "FluidNC sim"
  defp short_link(%{type: :fake_sim}), do: "Fake sim"
  defp short_link(%{type: :serial, port: port}), do: "USB " <> Path.basename(port)
  defp short_link(%{type: :tcp, host: host}), do: "Wi-Fi " <> host

  defp link_title(%CNC.Controllers.Controller{link: link}, _),
    do: CNC.Controllers.Controller.describe_link(link)

  defp link_title(nil, _), do: "Set by CNC_LINK"

  defp adapter_label("FakeSim"), do: "Fake sim"
  defp adapter_label("FluidNCSim"), do: "FluidNC sim"
  defp adapter_label(nil), do: ""
  defp adapter_label(name), do: name

  # A hold Resume can release (an open door must be closed first)
  defp held?(%State{state: s, controller: :hold}) when s in [:busy, :running], do: true
  defp held?(_), do: false

  # The cycle-start button: Resume a hold, or Start the loaded file when
  # Ready; nil when it does nothing (disabled, never removed).
  defp cycle(machine, program) do
    cond do
      held?(machine) -> :resume
      machine.state == :running and match?(%{waiting?: true}, machine.job) -> :next
      machine.state == :idle and program != nil -> :start
      true -> nil
    end
  end

  # Attention states get colour; normal ones stay calm (see the CSS).
  defp state_class(%State{state: s, controller: c})
       when s in [:busy, :running] and c in [:hold, :door],
       do: "hold"

  defp state_class(%State{state: state}), do: state

  defp state_icon(%State{state: :busy, controller: c}) when c in [:hold, :door],
    do: "hero-pause-circle"

  defp state_icon(%State{state: :running, controller: c}) when c in [:hold, :door],
    do: "hero-pause-circle"

  defp state_icon(%State{state: :running, job: %{mode: :check}}), do: "hero-magnifying-glass"
  defp state_icon(%State{state: :running}), do: "hero-play-circle"
  defp state_icon(%State{state: :idle}), do: "hero-check-circle"
  defp state_icon(%State{state: :alarm}), do: "hero-lock-closed"
  defp state_icon(%State{state: :jogging}), do: "hero-arrows-pointing-out"
  defp state_icon(%State{state: :homing}), do: "hero-home"
  defp state_icon(%State{state: :uploading}), do: "hero-arrow-up-tray"

  defp state_icon(%State{state: s}) when s in [:disconnected, :connecting],
    do: "hero-signal-slash"

  defp state_icon(_), do: "hero-arrow-path"

  defp state_label(%State{state: :running, job: %{mode: :check}}), do: "Checking"

  defp state_label(%State{state: :running, controller: c, job: %{single_block?: true}})
       when c not in [:hold, :door],
       do: "Single block"

  defp state_label(%State{state: :running, controller: c, job: %{mode: {:dry, _}}})
       when c not in [:hold, :door],
       do: "Dry run"

  defp state_label(%State{state: :running, controller: :hold}), do: "On hold"
  defp state_label(%State{state: :running, controller: :door}), do: "Door open"
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
      busy: "Busy",
      running: "Running"
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
