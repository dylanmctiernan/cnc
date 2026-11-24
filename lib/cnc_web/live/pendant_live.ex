defmodule CNCWeb.PendantLive do
  @moduledoc """
  The pendant (`/pendant`): a phone or tablet as a jog pendant. One job,
  the whole screen: the machine's state and Stop always at the top, where
  it is, the jog speed, and a big joystick (X/Y stick, Z slider) using the
  same `Joystick` hook and safety as the machine screen (heartbeat while
  held, stop on release, blur, hidden tab or lost connection). When the
  machine is locked, Unlock is offered, since a locked machine won't jog.
  More pendant functions (zeroing, a handwheel) come as they're needed.
  """
  use CNCWeb, :live_view

  alias CNC.Machine

  @impl true
  def mount(_params, session, socket) do
    cnc = CNCWeb.Instance.from_session(session)

    {:ok,
     socket
     |> assign(page_title: "Pendant", cnc: cnc, tier: :normal)
     |> assign(tiers: CNCWeb.Jog.tiers())}
  end

  # The state comes from CNCWeb.Shell (@shell_machine), which also handles Stop.
  @impl true
  def handle_info({:machine, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("jog", %{"x" => x, "y" => y, "tier" => tier} = params, socket) do
    with {:ok, vector} <- CNCWeb.Jog.analog_vector(x, y, params["z"] || 0),
         {:ok, tier} <- CNCWeb.Jog.tier(tier),
         do: Machine.jog(machine(socket), vector, tier)

    {:noreply, socket}
  end

  def handle_event("jog_heartbeat", _, socket) do
    Machine.jog_heartbeat(machine(socket))
    {:noreply, socket}
  end

  def handle_event("jog_stop", _, socket) do
    Machine.jog_stop(machine(socket))
    {:noreply, socket}
  end

  def handle_event("tier", %{"tier" => tier}, socket) do
    case CNCWeb.Jog.tier(tier) do
      {:ok, tier} -> {:noreply, assign(socket, tier: tier)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("unlock", _, socket) do
    Machine.unlock(machine(socket))
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.pendant flash={@flash}>
      <div class="ui-pendant" id="pendant">
        <header class="ui-pendant-top">
          <UI.machine_state machine={@shell_machine} id="pendant-state" />
          <span class="ui-pendant-pos num" id="pendant-pos">
            <span :for={{axis, v} <- position(@shell_machine)} class="ui-pendant-axis">
              <span class={"ui-axis-#{axis}"}>{String.upcase(to_string(axis))}</span> {v}
            </span>
          </span>
          <UI.stop_button id="pendant-stop" size="lg" />
        </header>

        <div :if={@shell_machine.state == :alarm} class="ui-pendant-locked" id="pendant-locked">
          <p>Locked: the position isn't confirmed. Unlock to jog from here.</p>
          <UI.button variant="primary" size="lg" id="pendant-unlock" phx-click="unlock">
            Unlock
          </UI.button>
        </div>
        <div
          :if={@shell_machine.state in [:disconnected, :connecting]}
          class="ui-pendant-locked"
          id="pendant-offline"
        >
          <p>{UI.state_word(@shell_machine.state)}: no controller to jog.</p>
        </div>

        <div class="ui-pendant-speed" role="group" aria-label="Jog speed">
          <button
            :for={{tier, {xy, z}} <- @tiers}
            type="button"
            id={"pendant-tier-#{tier}"}
            class={["ui-seg", @tier == tier && "is-on"]}
            aria-pressed={to_string(@tier == tier)}
            phx-click="tier"
            phx-value-tier={tier}
          >
            <span>{tier}</span>
            <span class="ui-seg-unit num">{xy}/{z} mm/s</span>
          </button>
        </div>

        <div
          id="pendant-joystick"
          class="cnc-joy ui-pendant-joy"
          phx-hook="Joystick"
          phx-update="ignore"
          data-tier={@tier}
          data-enabled={to_string(@shell_machine.state in [:idle, :jogging])}
        >
          <div
            class="cnc-joy-pad"
            role="application"
            aria-label="X/Y joystick: drag to jog, release to stop"
          >
            <span class="cnc-joy-label is-y" style="top: 0.5rem; left: 50%">Y+</span>
            <span class="cnc-joy-label is-y" style="bottom: 0.5rem; left: 50%">Y−</span>
            <span class="cnc-joy-label is-x" style="left: 0.75rem; top: 50%">X−</span>
            <span class="cnc-joy-label is-x" style="right: 0.75rem; top: 50%">X+</span>
            <span class="cnc-joy-knob"></span>
          </div>
          <div
            class="cnc-joy-z"
            role="application"
            aria-label="Z slider: drag up or down to jog, release to stop"
          >
            <span class="cnc-joy-label is-z" style="top: 0.5rem; left: 50%">Z+</span>
            <span class="cnc-joy-label is-z" style="bottom: 0.5rem; left: 50%">Z−</span>
            <span class="cnc-joy-knob"></span>
          </div>
        </div>

        <footer class="ui-pendant-foot">
          <.link navigate={~p"/"} class="ui-pendant-back" id="pendant-workstation">
            Open the workstation
          </.link>
        </footer>
      </div>
    </Layouts.pendant>
    """
  end

  defp machine(socket), do: socket.assigns.cnc.machine

  # Work position, two decimals (as the machine screen shows it).
  defp position(%{wpos: {x, y, z}}), do: [x: fmt(x), y: fmt(y), z: fmt(z)]
  defp position(_), do: [x: "–", y: "–", z: "–"]

  defp fmt(v) when is_number(v), do: :erlang.float_to_binary(v * 1.0, decimals: 2)
  defp fmt(_), do: "–"
end
