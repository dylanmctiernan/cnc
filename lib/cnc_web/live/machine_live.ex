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

  alias CNC.Machine
  alias CNC.Machine.State

  @tiers [fine: {5, 1}, normal: {20, 5}, fast: {50, 10}]
  @steps [0.1, 1, 10, 50]
  @console_rows 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Machine.subscribe()
    machine = Machine.status()

    {:ok,
     socket
     |> assign(machine: machine, tier: :normal, step: 10)
     |> assign(frame: :work, action_error: nil, control_mode: :joystick, step_axis: :x)
     |> assign(more?: false)
     |> assign(details?: false, polls?: false, raw_error: nil, commands?: false)
     |> assign(command_help: CNCWeb.ConsoleHelp.sections())
     |> assign(tiers: @tiers, steps: @steps)
     |> stream_configure(:console, dom_id: &"log-#{&1.id}")
     |> stream(:console, [])
     |> push_pos(machine)}
  end

  @impl true
  def handle_info({:machine, %State{} = machine}, socket) do
    socket =
      if machine.travel != socket.assigns.machine.travel,
        do: push_event(socket, "travel", %{travel: travel_list(machine.travel)}),
        else: socket

    {:noreply, socket |> assign(machine: machine) |> push_pos(machine)}
  end

  def handle_info({:machine_console, entry}, socket),
    do: {:noreply, stream_insert(socket, :console, entry, limit: -@console_rows)}

  @impl true
  def handle_event("jog", %{"x" => x, "y" => y, "tier" => tier} = params, socket) do
    with {:ok, vector} <- analog_vector(x, y, params["z"] || 0), {:ok, tier} <- tier(tier) do
      Machine.jog(vector, tier)
    end

    {:noreply, socket}
  end

  def handle_event("jog_heartbeat", _, socket), do: tap_noreply(socket, &Machine.jog_heartbeat/0)
  def handle_event("jog_stop", _, socket), do: tap_noreply(socket, &Machine.jog_stop/0)

  # Esc: stop jogging and hold.
  def handle_event("stop", _, socket) do
    Machine.jog_stop()
    Machine.feed_hold()
    {:noreply, socket}
  end

  def handle_event("unlock", _, socket), do: tap_noreply(socket, &Machine.unlock/0)
  def handle_event("home", _, socket), do: tap_noreply(socket, &Machine.home/0)
  def handle_event("feed_hold", _, socket), do: tap_noreply(socket, &Machine.feed_hold/0)
  def handle_event("resume", _, socket), do: tap_noreply(socket, &Machine.resume/0)
  def handle_event("reset", _, socket), do: tap_noreply(socket, &Machine.reset/0)

  def handle_event("step", %{"x" => x, "y" => y} = params, socket) do
    with {:ok, vector} when vector != {0, 0, 0} <- vector(x, y, params["z"] || 0),
         do: Machine.jog_step(vector, socket.assigns.step)

    {:noreply, socket}
  end

  def handle_event("tier", %{"tier" => tier}, socket) do
    case tier(tier) do
      {:ok, tier} -> {:noreply, assign(socket, tier: tier)}
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
  def handle_event("close_more", _, socket), do: {:noreply, assign(socket, more?: false)}

  def handle_event("control_mode", %{"mode" => mode}, socket) when mode in ~w(joystick step zero),
    do: {:noreply, assign(socket, control_mode: String.to_existing_atom(mode))}

  def handle_event("step_axis", %{"axis" => axis}, socket) when axis in ~w(x y z),
    do: {:noreply, assign(socket, step_axis: String.to_existing_atom(axis))}

  def handle_event("frame", %{"frame" => frame}, socket) when frame in ~w(work machine),
    do: {:noreply, assign(socket, frame: String.to_existing_atom(frame))}

  def handle_event("zero", %{"axes" => axes}, socket) do
    axes = for c <- String.graphemes(axes), c in ~w(x y z), do: String.to_existing_atom(c)
    if axes != [], do: Machine.set_work_zero(axes)
    {:noreply, assign(socket, action_error: nil)}
  end

  def handle_event("go_to_zero", _, socket) do
    error =
      case Machine.go_to_work_zero() do
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

    {:noreply, assign(socket, action_error: error)}
  end

  # Console traffic is only subscribed to while the panel is open. Subscribe
  # before loading history; overlapping entries share a DOM id, so no dupes.
  def handle_event("toggle_details", _, %{assigns: %{details?: false}} = socket) do
    Machine.subscribe_console()

    {:noreply,
     socket
     |> assign(details?: true)
     |> stream(:console, Machine.console(), reset: true)}
  end

  def handle_event("toggle_details", _, socket) do
    Machine.unsubscribe_console()
    Machine.unsubscribe_polls()

    {:noreply,
     socket |> assign(details?: false, polls?: false) |> stream(:console, [], reset: true)}
  end

  def handle_event("toggle_polls", _, %{assigns: %{polls?: polls?}} = socket) do
    if polls?, do: Machine.unsubscribe_polls(), else: Machine.subscribe_polls()
    {:noreply, assign(socket, polls?: !polls?)}
  end

  def handle_event("send_raw", %{"line" => line}, socket) do
    error =
      case Machine.send_raw(line) do
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
          <span
            :if={@machine.controller_info.simulated?}
            class="cnc-sim"
            title="Connected to a simulator, not a real machine"
          >
            Simulator
          </span>
          <dl class="cnc-meta">
            <div>
              <dt>link</dt>
              <dd class={if @machine.connected?, do: "is-on", else: "is-off"}>
                {adapter_label(@machine.adapter)} {if @machine.connected?,
                  do: "connected",
                  else: "not connected"}
              </dd>
            </div>
            <div>
              <dt>firmware</dt>
              <dd>{firmware_label(@machine.controller_info)}</dd>
            </div>
            <div>
              <dt>reports</dt>
              <dd>{controller_label(@machine)}</dd>
            </div>
            <div>
              <dt>feed</dt>
              <dd>{if @machine.feed, do: "#{round(@machine.feed)} mm/min", else: "—"}</dd>
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
            <.link navigate={~p"/settings"} class="cnc-btn">Settings</.link>
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
                phx-click={JS.push("toggle_details") |> JS.push("close_more")}
              >
                {if @details?, do: "Hide console", else: "Console"}
              </button>
              <.link navigate={~p"/settings"} class="cnc-btn">Settings</.link>
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
          <p :if={note = error_text(@machine.last_error)} class="cnc-note">
            {note}
            <span :if={
              @machine.last_error == {:link, :no_response} and
                @machine.controller_info.firmware == "grblHAL" and @machine.controller_info.simulated?
            }>
              The grblHAL simulator is known to stall now and then; it recovers on its own.
            </span>
          </p>
          <p :if={@action_error} class="cnc-note">{@action_error}</p>
          <p :for={{axis, got, max} <- @machine.travel_issues} class="cnc-note cnc-note--warn">
            The controller reports {axis_name(axis)} travel of {round(got)} mm, more than this
            machine's {round(max)} mm. Using {round(max)} mm. Check ${travel_setting(axis)} with $$.
          </p>
        </div>

        <section class="cnc-view" aria-label="Bed and Z">
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
          >
            <canvas
              role="img"
              aria-label="Top-down view of the bed with the tool position, and Z height"
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
            <span class="cnc-num">{fmt(axis_value(shown(@machine, @frame), i))}</span>
            <button
              :if={frame(@machine, @frame) == :work}
              type="button"
              class="cnc-btn cnc-btn--zero"
              phx-click="zero"
              phx-value-axes={String.downcase(axis)}
              disabled={@machine.state != :idle}
              aria-label={"Set work #{axis} to zero here"}
            >
              Zero
            </button>
          </div>
          <p :if={@machine.wpos} class="cnc-sub cnc-dro-other">
            {if frame(@machine, @frame) == :work, do: "machine", else: "work"} {xyz_label(
              if(frame(@machine, @frame) == :work, do: @machine.mpos, else: @machine.wpos)
            )}
          </p>
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
                :for={axis <- ~w(X Y Z)}
                type="button"
                class={["cnc-btn", "is-#{String.downcase(axis)}"]}
                phx-click="zero"
                phx-value-axes={String.downcase(axis)}
                disabled={@machine.state != :idle}
              >
                Zero {axis}
              </button>
            </div>
            <div class="cnc-zero-axes">
              <button
                type="button"
                class="cnc-btn"
                phx-click="zero"
                phx-value-axes="xy"
                disabled={@machine.state != :idle}
              >
                Zero X and Y
              </button>
              <button
                type="button"
                class="cnc-btn"
                phx-click="go_to_zero"
                disabled={not can_go_to_zero?(@machine)}
              >
                Go to work zero
              </button>
            </div>
            <p class="cnc-sub">
              Zero sets the work position to 0 where the tool is now. Go to work zero
              lifts Z, then moves to X0 Y0.
            </p>
          </div>
        </section>

        <%!-- Workstation only: details and keyboard --%>
        <aside class="cnc-side" aria-label="Details and keyboard">
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

        <section :if={@details?} id="console" class="cnc-console" aria-label="Controller console">
          <div class="cnc-console-bar">
            <h2 class="cnc-h">Console</h2>
            <label class="cnc-check">
              <input type="checkbox" checked={@polls?} phx-click="toggle_polls" /> Show status polls
            </label>
            <button type="button" class="cnc-btn cnc-btn--quiet" phx-click="clear_console">
              Clear
            </button>
            <button type="button" class="cnc-btn cnc-console-close" phx-click="toggle_details">
              Close
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
          </div>
          <div :if={@commands?} id="console-help" class="cnc-help">
            <p class="cnc-help-lead">
              Click a command to put it in the input below; nothing is sent until you press Enter.
              <button type="button" class="cnc-link" phx-click="ask_controller">
                Ask the controller for its own list
              </button>
            </p>
            <p :if={@machine.adapter == "Sim"} class="cnc-help-note">
              The built-in simulator understands $, $$, $X, $H, $J=, $130–$132, ?, ! and ~.
              Connect the grblHAL simulator to try the rest.
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

  defp tap_noreply(socket, fun) do
    fun.()
    {:noreply, socket}
  end

  defp push_pos(socket, %State{mpos: {x, y, z}} = m) do
    {jx, jy, jz} = m.jog
    wco = if m.wco, do: Tuple.to_list(m.wco)
    push_event(socket, "pos", %{x: x, y: y, z: z, state: m.state, jog: [jx, jy, jz], wco: wco})
  end

  defp push_pos(socket, _), do: socket

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

  defp fmt(nil), do: "—"
  defp fmt(mm), do: :erlang.float_to_binary(mm / 1, decimals: 3)

  defp travel_json(travel), do: Jason.encode!(travel_list(travel))

  defp travel_list({{x0, x1}, {y0, y1}, {z0, z1}}), do: [[x0, x1], [y0, y1], [z0, z1]]
  defp travel_list(_), do: [[0, 1250], [0, 1250], [-100, 0]]

  defp adapter_label("Sim"), do: "Simulator"
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
  defp firmware_label(%{firmware: fw, version: v}), do: "#{fw} #{v}"

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
