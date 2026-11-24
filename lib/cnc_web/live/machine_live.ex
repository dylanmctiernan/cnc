defmodule CNCWeb.MachineLive do
  @moduledoc """
  The machine screen: bed view, position readout, and jog controls.

  Renders only what `CNC.Machine` reports. Keyboard jogging lives in the
  `JogKeys` hook; the bed is drawn by the `BedView` hook from `"pos"` events.
  """
  use CNCWeb, :live_view

  alias CNC.Machine
  alias CNC.Machine.State

  @tiers [fine: 5, normal: 20, fast: 50]
  @steps [0.1, 1, 10, 50]
  @console_rows 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Machine.subscribe()
    machine = Machine.status()

    {:ok,
     socket
     |> assign(machine: machine, tier: :normal, step: 10, help?: false)
     |> assign(details?: false, polls?: false)
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
  def handle_event("jog", %{"x" => x, "y" => y, "tier" => tier}, socket) do
    with {:ok, vector} <- vector(x, y), {:ok, tier} <- tier(tier) do
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

  def handle_event("step", %{"x" => x, "y" => y}, socket) do
    with {:ok, vector} when vector != {0, 0} <- vector(x, y),
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

  def handle_event("clear_console", _, socket),
    do: {:noreply, stream(socket, :console, [], reset: true)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="jog-keys" phx-hook="JogKeys" data-tier={@tier} hidden></div>

      <div class="cnc">
        <header class="cnc-bar">
          <h1 class="cnc-title">CNC</h1>
          <span class="cnc-meta">{adapter_label(@machine.adapter)}</span>
          <span class={["cnc-meta", !@machine.connected? && "is-off"]}>
            {if @machine.connected?, do: "Connected", else: "Not connected"}
          </span>
          <span class={"cnc-state cnc-state--#{@machine.state}"} role="status">
            {state_label(@machine)}
          </span>
        </header>

        <section
          id="bed"
          class="cnc-bed"
          phx-hook="BedView"
          phx-update="ignore"
          data-travel={travel_json(@machine.travel)}
          data-x={pos(@machine, 0)}
          data-y={pos(@machine, 1)}
          data-state={@machine.state}
        >
          <canvas role="img" aria-label="Top-down view of the bed with the tool position"></canvas>
          <button
            type="button"
            class="cnc-btn cnc-btn--quiet cnc-clear"
            phx-click={JS.dispatch("bed:clear-trail", to: "#bed")}
          >
            Clear trail
          </button>
        </section>

        <aside class="cnc-rail">
          <div :if={@machine.state == :alarm} class="cnc-lock" role="alert">
            <p class="cnc-lock-title">Locked</p>
            <p>{alarm_text(@machine.alarm)}</p>
            <div class="cnc-row">
              <button type="button" class="cnc-btn cnc-btn--primary" phx-click="home">Home</button>
              <button type="button" class="cnc-btn" phx-click="unlock">Unlock</button>
            </div>
          </div>

          <p :if={note = error_text(@machine.last_error)} class="cnc-note">{note}</p>

          <section class="cnc-dro" aria-label="Position">
            <div class="cnc-dro-row">
              <span class="cnc-axis">X</span>
              <span class="cnc-num">{fmt(pos(@machine, 0))}</span>
            </div>
            <div class="cnc-dro-row">
              <span class="cnc-axis">Y</span>
              <span class="cnc-num">{fmt(pos(@machine, 1))}</span>
            </div>
            <p class="cnc-sub">Machine position in mm</p>
            <p :if={@machine.wpos && @machine.wpos != @machine.mpos} class="cnc-sub">
              Work position X {fmt(elem(@machine.wpos, 0))}, Y {fmt(elem(@machine.wpos, 1))}
            </p>
          </section>

          <section class="cnc-group">
            <h2 class="cnc-h">Speed</h2>
            <div class="cnc-seg" role="group" aria-label="Jog speed">
              <button
                :for={{tier, mm_s} <- @tiers}
                type="button"
                class="cnc-btn"
                aria-pressed={to_string(@tier == tier)}
                phx-click="tier"
                phx-value-tier={tier}
              >
                {String.capitalize(to_string(tier))} <span class="cnc-unit">{mm_s} mm/s</span>
              </button>
            </div>
          </section>

          <section class="cnc-group">
            <h2 class="cnc-h">Step</h2>
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
              <.step_button x={0} y={1} label="Y+" idle?={@machine.state == :idle} />
              <.step_button x={-1} y={0} label="X−" idle?={@machine.state == :idle} />
              <span class="cnc-pad-mm">{@step} mm</span>
              <.step_button x={1} y={0} label="X+" idle?={@machine.state == :idle} />
              <.step_button x={0} y={-1} label="Y−" idle?={@machine.state == :idle} />
            </div>
          </section>

          <section class="cnc-group">
            <h2 class="cnc-h">Controller</h2>
            <div class="cnc-row">
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
            </div>
            <button
              type="button"
              class="cnc-btn cnc-btn--quiet"
              phx-click="toggle_details"
              aria-expanded={to_string(@details?)}
              aria-controls="console"
            >
              {if @details?, do: "Hide details and console", else: "Details and console"}
            </button>
            <dl :if={@details?} class="cnc-facts">
              <dt>Reports</dt>
              <dd>{controller_label(@machine)}</dd>
              <dt>Feed</dt>
              <dd>{if @machine.feed, do: "#{round(@machine.feed)} mm/min", else: "—"}</dd>
              <dt>Planner</dt>
              <dd>{buffer_label(@machine.buffer, 0, "blocks")}</dd>
              <dt>Serial buffer</dt>
              <dd>{buffer_label(@machine.buffer, 1, "bytes")}</dd>
              <dt>Awaiting ack</dt>
              <dd>{pluralize(@machine.awaiting_ack, "line")}</dd>
              <dt>Work offset</dt>
              <dd>{xyz_label(@machine.wco)}</dd>
              <dt>Travel</dt>
              <dd>
                {travel_label(@machine.travel)}
                <span class="cnc-sub-inline">
                  {if @machine.travel_source == :controller,
                    do: "from the controller",
                    else: "from config"}
                </span>
              </dd>
              <dt :if={@machine.alarm}>Locked because</dt>
              <dd :if={@machine.alarm}>{lock_label(@machine.alarm)}</dd>
            </dl>
          </section>

          <section class="cnc-group">
            <button type="button" class="cnc-btn cnc-btn--quiet" phx-click="toggle_help">
              {if @help?, do: "Hide keyboard shortcuts", else: "Keyboard shortcuts"}
            </button>
            <dl :if={@help?} class="cnc-keys">
              <dt>Arrow keys</dt>
              <dd>Jog while held</dd>
              <dt>Shift</dt>
              <dd>Fast while held</dd>
              <dt>Option</dt>
              <dd>Fine while held</dd>
              <dt>Esc</dt>
              <dd>Stop and hold</dd>
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
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :x, :integer, required: true
  attr :y, :integer, required: true
  attr :label, :string, required: true
  attr :idle?, :boolean, required: true

  defp step_button(assigns) do
    ~H"""
    <button
      type="button"
      class="cnc-btn"
      phx-click="step"
      phx-value-x={@x}
      phx-value-y={@y}
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

  defp push_pos(socket, %State{mpos: {x, y, _}} = m) do
    {jx, jy} = m.jog
    push_event(socket, "pos", %{x: x, y: y, state: m.state, jog: [jx, jy]})
  end

  defp push_pos(socket, _), do: socket

  defp vector(x, y) do
    with {x, ""} when x in -1..1 <- Integer.parse(to_string(x)),
         {y, ""} when y in -1..1 <- Integer.parse(to_string(y)) do
      {:ok, {x, y}}
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

  defp travel_list({{x0, x1}, {y0, y1}, _z}), do: [[x0, x1], [y0, y1]]
  defp travel_list(_), do: [[0, 1250], [0, 1250]]

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

  defp travel_label({{x0, x1}, {y0, y1}, _}),
    do: "X #{round(x0)} to #{round(x1)}, Y #{round(y0)} to #{round(y1)} mm"

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

  defp error_text(nil), do: nil
  defp error_text({:jog, :heartbeat_lost}), do: "Jog stopped: the keyboard stopped responding."
  defp error_text({:error, 15}), do: "Stopped: that move would leave the travel area."
  defp error_text({:error, 8}), do: "The controller wasn't ready for that command."
  defp error_text({:error, code}), do: "The controller rejected the last command (error #{code})."
end
