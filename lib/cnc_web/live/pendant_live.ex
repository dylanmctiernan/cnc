defmodule CNCWeb.PendantLive do
  @moduledoc """
  The pendant (`/pendant`): a phone or tablet as a jog pendant. One job,
  the whole screen: the machine's state and Stop always at the top, where
  it is, the jog speed, and a big joystick (X/Y stick, Z slider) using the
  same `Joystick` hook and safety as the machine screen (heartbeat while
  held, stop on release, blur, hidden tab or lost connection). When the
  machine is locked, Unlock is offered, since a locked machine won't jog;
  when it's held (Stop latches a hold), Resume releases it, so a stop made
  here can be released here.
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

  def handle_event("resume", _, socket) do
    Machine.resume(machine(socket))
    {:noreply, socket}
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
        <%!-- Like a physical pendant: the state and where it is, then the
             cycle-start button (Resume, or Unlock when locked; always there,
             enabled only when it does something) and Stop, side by side.
             Nothing here ever appears or disappears, so nothing shifts. --%>
        <header class="ui-pendant-top">
          <UI.machine_state machine={@shell_machine} id="pendant-state" />
          <span class="ui-pendant-pos num" id="pendant-pos">
            <span :for={{axis, v} <- position(@shell_machine)} class="ui-pendant-axis">
              <span class={"ui-axis-#{axis}"}>{String.upcase(to_string(axis))}</span> {v}
            </span>
          </span>
          <button
            type="button"
            id="pendant-action"
            class="ui-pendant-cycle"
            data-action={action(@shell_machine)}
            phx-click={action(@shell_machine)}
            disabled={action(@shell_machine) == nil}
          >
            <%= if @shell_machine.state == :alarm do %>
              <.icon name="hero-lock-open" class="ui-btn-icon" /> Unlock
            <% else %>
              <.icon name="hero-play" class="ui-btn-icon" /> Resume
            <% end %>
          </button>
          <UI.stop_button id="pendant-stop" size="lg" />
        </header>

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

        <%!-- The stick, and over it (only when it can't jog) why not and
             what to press --%>
        <div class="ui-pendant-stage">
          <div
            :if={cover(@shell_machine)}
            class="ui-pendant-cover"
            id={"pendant-" <> elem(cover(@shell_machine), 0)}
          >
            <p class={"ui-pendant-cover-msg is-#{elem(cover(@shell_machine), 1)}"}>
              {elem(cover(@shell_machine), 2)}
            </p>
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

  # What the cycle-start button does now (nil: nothing, so it's disabled)
  defp action(%{state: :alarm}), do: "unlock"
  defp action(%{state: :busy, controller: :hold}), do: "resume"
  defp action(_), do: nil

  # Over the stick when it can't jog: {id, tone, message}
  defp cover(%{state: :alarm}),
    do: {"locked", "danger", "Locked: the position isn't confirmed. Press Unlock to jog."}

  defp cover(%{state: :busy, controller: :hold}),
    do: {"held", "warn", "On hold: stopped, position kept. Press Resume to carry on."}

  defp cover(%{state: :busy, controller: :door}),
    do: {"door", "warn", "Door open: close it, then press Resume."}

  defp cover(%{state: s}) when s in [:disconnected, :connecting],
    do: {"offline", "neutral", "#{UI.state_word(s)}: no controller to jog."}

  defp cover(_), do: nil

  # Work position, two decimals (as the machine screen shows it).
  defp position(%{wpos: {x, y, z}}), do: [x: fmt(x), y: fmt(y), z: fmt(z)]
  defp position(_), do: [x: "–", y: "–", z: "–"]

  defp fmt(v) when is_number(v), do: :erlang.float_to_binary(v * 1.0, decimals: 2)
  defp fmt(_), do: "–"
end
