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
     |> assign(machine: machine, tier: :normal, step: 10, help?: false)
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

  def handle_event("toggle_help", _, socket), do: {:noreply, update(socket, :help?, &(!&1))}

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

      <div class={["cnc", @details? && "has-console"]}>
        <header class="cnc-bar">
          <div class={"cnc-state cnc-state--#{@machine.state}"} role="status">
            {state_label(@machine)}
          </div>
          <dl class="cnc-meta">
            <div>
              <dt>link</dt>
              <dd class={!@machine.connected? && "is-off"}>
                {adapter_label(@machine.adapter)} {if @machine.connected?,
                  do: "connected",
                  else: "not connected"}
              </dd>
            </div>
            <div>
              <dt>controller</dt>
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
        </header>

        <div class="cnc-messages">
          <div :if={@machine.state == :alarm} class="cnc-lock" role="alert">
            <span class="cnc-lock-tag">Locked</span>
            <p>{alarm_text(@machine.alarm)}</p>
            <div class="cnc-row">
              <button type="button" class="cnc-btn cnc-btn--primary" phx-click="home">Home</button>
              <button type="button" class="cnc-btn" phx-click="unlock">Unlock</button>
            </div>
          </div>
          <p :if={note = error_text(@machine.last_error)} class="cnc-note">{note}</p>
          <p :for={{axis, got, max} <- @machine.travel_issues} class="cnc-note cnc-note--warn">
            The controller reports {axis_name(axis)} travel of {round(got)} mm, more than this
            machine's {round(max)} mm. Using {round(max)} mm. Check ${travel_setting(axis)} with $$.
          </p>
        </div>

        <section class="cnc-view" aria-label="Bed and Z">
          <div class="cnc-view-bar">
            <h2 class="cnc-h">Top view and Z</h2>
            <button
              type="button"
              class="cnc-btn cnc-btn--quiet"
              phx-click={JS.dispatch("bed:clear-trail", to: "#bed")}
            >
              Clear trail
            </button>
          </div>
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

        <aside class="cnc-rail">
          <section class="cnc-dro" aria-label="Machine position">
            <h2 class="cnc-h">Machine position <span class="cnc-unit">mm</span></h2>
            <div :for={{axis, i} <- [{"X", 0}, {"Y", 1}, {"Z", 2}]} class="cnc-dro-row">
              <span class="cnc-axis">{axis}</span>
              <span class="cnc-num">{fmt(pos(@machine, i))}</span>
            </div>
            <p :if={@machine.wpos && @machine.wpos != @machine.mpos} class="cnc-sub">
              work {xyz_label(@machine.wpos)}
            </p>
          </section>

          <section class="cnc-group">
            <h2 class="cnc-h">Jog speed</h2>
            <div class="cnc-seg" role="group" aria-label="Jog speed">
              <button
                :for={{tier, {xy, z}} <- @tiers}
                type="button"
                class="cnc-btn"
                aria-pressed={to_string(@tier == tier)}
                phx-click="tier"
                phx-value-tier={tier}
              >
                {tier}<span class="cnc-unit">{xy}/{z}</span>
              </button>
            </div>
            <p class="cnc-sub">X/Y and Z in mm/s</p>
          </section>

          <section class="cnc-group">
            <h2 class="cnc-h">Joystick</h2>
            <div
              id="joystick"
              class={["cnc-joy", @machine.state not in [:idle, :jogging] && "is-off"]}
              phx-hook="Joystick"
              phx-update="ignore"
              data-tier={@tier}
            >
              <div
                class="cnc-joy-pad"
                role="application"
                aria-label="X/Y joystick: drag to jog, release to stop"
              >
                <span class="cnc-joy-label" style="top: 0.25rem; left: 50%">Y+</span>
                <span class="cnc-joy-label" style="bottom: 0.25rem; left: 50%">Y−</span>
                <span class="cnc-joy-label" style="left: 0.5rem; top: 50%">X−</span>
                <span class="cnc-joy-label" style="right: 0.5rem; top: 50%">X+</span>
                <span class="cnc-joy-knob"></span>
              </div>
              <div
                class="cnc-joy-z"
                role="application"
                aria-label="Z slider: drag up or down to jog, release to stop"
              >
                <span class="cnc-joy-label" style="top: 0.25rem; left: 50%">Z+</span>
                <span class="cnc-joy-label" style="bottom: 0.25rem; left: 50%">Z−</span>
                <span class="cnc-joy-knob"></span>
              </div>
            </div>
            <p class="cnc-sub">Push further to go faster, up to the jog speed. Release to stop.</p>
          </section>

          <section class="cnc-group">
            <h2 class="cnc-h">Step <span class="cnc-unit">mm</span></h2>
            <div class="cnc-seg" role="group" aria-label="Step size">
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
            <div class="cnc-pad">
              <.step_button x={0} y={1} z={0} label="Y+" area="yp" idle?={@machine.state == :idle} />
              <.step_button x={-1} y={0} z={0} label="X−" area="xm" idle?={@machine.state == :idle} />
              <span class="cnc-pad-mm">{@step}</span>
              <.step_button x={1} y={0} z={0} label="X+" area="xp" idle?={@machine.state == :idle} />
              <.step_button x={0} y={-1} z={0} label="Y−" area="ym" idle?={@machine.state == :idle} />
              <.step_button x={0} y={0} z={1} label="Z+" area="zp" idle?={@machine.state == :idle} />
              <.step_button x={0} y={0} z={-1} label="Z−" area="zm" idle?={@machine.state == :idle} />
            </div>
          </section>

          <dl :if={@details?} class="cnc-facts" aria-label="Controller details">
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

          <section class="cnc-group">
            <button type="button" class="cnc-btn cnc-btn--quiet" phx-click="toggle_help">
              {if @help?, do: "Hide keyboard shortcuts", else: "Keyboard shortcuts"}
            </button>
            <dl :if={@help?} class="cnc-keys">
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
              <dt>?</dt>
              <dd>Show or hide this list</dd>
            </dl>
          </section>
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
      </div>
    </Layouts.app>
    """
  end

  attr :x, :integer, required: true
  attr :y, :integer, required: true
  attr :z, :integer, required: true
  attr :label, :string, required: true
  attr :area, :string, required: true
  attr :idle?, :boolean, required: true

  defp step_button(assigns) do
    ~H"""
    <button
      type="button"
      class="cnc-btn"
      style={"grid-area: #{@area}"}
      phx-click="step"
      phx-value-x={@x}
      phx-value-y={@y}
      phx-value-z={@z}
      disabled={!@idle?}
    >
      {@label}
    </button>
    """
  end

  ## Helpers

  defp tap_noreply(socket, fun) do
    fun.()
    {:noreply, socket}
  end

  defp push_pos(socket, %State{mpos: {x, y, z}} = m) do
    {jx, jy, jz} = m.jog
    push_event(socket, "pos", %{x: x, y: y, z: z, state: m.state, jog: [jx, jy, jz]})
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
