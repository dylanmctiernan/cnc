defmodule CNCWeb.PendantLive do
  @moduledoc """
  The pendant (`/pendant`): a phone or tablet at the machine, like a
  handheld pendant (a Haas RJH, say). Always at the top, never moving: the
  machine's state and work position, the cycle button (Start, Resume,
  Unlock or Next line: what Cycle Start does now, disabled when nothing)
  and Hold. Below, the modes a pendant is for, as on the workstation:

    * **Jog** — the stick (X/Y) and Z slider: the `Joystick` hook, with the
      same safety as the machine screen (heartbeat while held, stop on
      release, blur, hidden tab or lost connection)
    * **Inc** — one press, one step: axis, step size, − and +
    * **Zero** — touch off: Zero X/Y, Zero Z (with Undo), Go to X0 Y0
    * **Job** — the loaded program: Start (after the same check as the
      workstation), and while it runs its progress, time left, feed and
      rapid overrides, single block, Abort

  Loading files and typing commands stay on the workstation.
  """
  use CNCWeb, :live_view

  import CNCWeb.Run, only: [fit: 2, fit_issue: 1, fraction: 2, time_left: 4, duration: 1]

  alias CNC.{Machine, Program}

  @steps [0.1, 1, 10, 50]
  @modes [jog: "Jog", inc: "Inc", zero: "Zero", job: "Job"]

  @impl true
  def mount(_params, session, socket) do
    cnc = CNCWeb.Instance.from_session(session)
    if connected?(socket), do: Program.subscribe(cnc.program_topic)
    program = Program.current(cnc.program)

    {:ok,
     socket
     |> assign(page_title: "Pendant", cnc: cnc, tier: :normal, tiers: CNCWeb.Jog.tiers())
     |> assign(program: program, modes: @modes, steps: @steps)
     # A job running when the pendant opens: show it
     |> assign(mode: if(socket.assigns.shell_machine.job, do: :job, else: :jog))
     |> assign(seen_job: (job = socket.assigns.shell_machine.job) && job.started_at)
     |> assign(step_axis: :x, step: 1, undo_zero: nil, error: nil)
     |> assign(start_check?: false, abort_check?: false)
     # This page's own manifest: added to a home screen, it opens here
     |> assign(manifest: ~p"/pendant.webmanifest", app_title: "Pendant")}
  end

  # The state comes from CNCWeb.Shell (@shell_machine, assigned before this
  # runs), which also handles Hold. A job starting (here or on the
  # workstation) shows Job: a job this page hasn't seen yet.
  @impl true
  def handle_info({:machine, machine}, socket) do
    key = machine.job && machine.job.started_at

    socket =
      if key && key != socket.assigns.seen_job,
        do: assign(socket, mode: :job, seen_job: key),
        else: socket

    {:noreply, socket}
  end

  def handle_info({:program, program}, socket), do: {:noreply, assign(socket, program: program)}

  @impl true
  def handle_event("mode", %{"mode" => mode}, socket) when mode in ~w(jog inc zero job),
    do: {:noreply, assign(socket, mode: String.to_existing_atom(mode), error: nil)}

  # Jog: the stick
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

  # Inc: one press, one step
  def handle_event("step_axis", %{"axis" => axis}, socket) when axis in ~w(x y z),
    do: {:noreply, assign(socket, step_axis: String.to_existing_atom(axis))}

  def handle_event("step_size", %{"mm" => mm}, socket) do
    case Enum.find(@steps, &(to_string(&1) == mm)) do
      nil -> {:noreply, socket}
      step -> {:noreply, assign(socket, step: step)}
    end
  end

  def handle_event("step", %{"dir" => dir}, socket) when dir in ~w(-1 1) do
    d = String.to_integer(dir)
    vector = for a <- [:x, :y, :z], do: if(a == socket.assigns.step_axis, do: d, else: 0)

    error =
      case Machine.jog_step(machine(socket), List.to_tuple(vector), socket.assigns.step) do
        {:error, :at_limit} -> "That's the edge of the travel."
        _ -> nil
      end

    {:noreply, assign(socket, error: error)}
  end

  # The cycle button: what Cycle Start does now
  def handle_event("cycle", _, socket) do
    case cycle(socket.assigns.shell_machine, socket.assigns.program) do
      :unlock -> send_to(socket, &Machine.unlock/1)
      :resume -> send_to(socket, &Machine.resume/1)
      :next -> send_to(socket, &Machine.resume/1)
      :start -> {:noreply, assign(socket, start_check?: true, mode: :job)}
      nil -> {:noreply, socket}
    end
  end

  # Kept for the hold message's Resume and older links
  def handle_event("resume", _, socket), do: send_to(socket, &Machine.resume/1)
  def handle_event("unlock", _, socket), do: send_to(socket, &Machine.unlock/1)

  # Zero: touch off, with Undo
  def handle_event("zero", %{"axes" => axes}, socket) when axes in ~w(xy z) do
    axes = if axes == "xy", do: [:x, :y], else: [:z]
    before = socket.assigns.shell_machine.wco

    case Machine.set_work_zero(machine(socket), axes) do
      :ok ->
        {:noreply, assign(socket, undo_zero: before && %{axes: axes, wco: before}, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: zero_error(reason))}
    end
  end

  def handle_event("undo_zero", _, %{assigns: %{undo_zero: %{axes: axes, wco: wco}}} = socket) do
    values = for a <- axes, do: {a, elem(wco, Enum.find_index([:x, :y, :z], &(&1 == a)))}

    case Machine.set_work_offset(machine(socket), values) do
      :ok -> {:noreply, assign(socket, undo_zero: nil)}
      {:error, reason} -> {:noreply, assign(socket, error: zero_error(reason))}
    end
  end

  def handle_event("go_to_zero", _, socket) do
    case Machine.go_to_work_zero(machine(socket)) do
      :ok -> {:noreply, assign(socket, error: nil)}
      {:error, reason} -> {:noreply, assign(socket, error: zero_error(reason))}
    end
  end

  # Job: start (after the check), overrides, single block, abort
  def handle_event("start_check", _, socket), do: {:noreply, assign(socket, start_check?: true)}
  def handle_event("cancel_start", _, socket), do: {:noreply, assign(socket, start_check?: false)}

  def handle_event("confirm_start", _, %{assigns: %{program: %Program{} = p}} = socket) do
    error =
      case Machine.run(machine(socket), p.name, p.text) do
        :ok -> nil
        {:error, _} -> "Couldn't start: the machine must be Ready."
      end

    {:noreply, assign(socket, start_check?: false, error: error)}
  end

  def handle_event("feed_override", %{"op" => op}, socket) when op in ~w(reset plus10 minus10) do
    Machine.feed_override(machine(socket), String.to_existing_atom(op))
    {:noreply, socket}
  end

  def handle_event("rapid_override", %{"percent" => p}, socket) when p in ~w(100 50 25) do
    Machine.rapid_override(machine(socket), String.to_integer(p))
    {:noreply, socket}
  end

  def handle_event("single_block", %{"on" => on}, socket) when on in ~w(true false) do
    Machine.single_block(machine(socket), on == "true")
    {:noreply, socket}
  end

  def handle_event("abort_job", _, socket), do: {:noreply, assign(socket, abort_check?: true)}
  def handle_event("cancel_abort", _, socket), do: {:noreply, assign(socket, abort_check?: false)}

  def handle_event("confirm_abort", _, socket) do
    Machine.abort(machine(socket))
    {:noreply, assign(socket, abort_check?: false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.pendant flash={@flash}>
      <div class="ui-pendant" id="pendant">
        <%!-- Like a physical pendant: the state and where it is, then the
             cycle button and Hold, side by side. Nothing here ever appears or
             disappears, so nothing shifts. --%>
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
            data-action={cycle(@shell_machine, @program)}
            phx-click="cycle"
            disabled={cycle(@shell_machine, @program) == nil}
          >
            <.icon name={cycle_icon(@shell_machine, @program)} class="ui-btn-icon" />
            {cycle_label(@shell_machine, @program)}
          </button>
          <UI.hold_button id="pendant-hold" size="lg" />
        </header>

        <nav class="ui-pendant-modes" role="group" aria-label="Mode">
          <button
            :for={{mode, label} <- @modes}
            type="button"
            id={"pendant-mode-#{mode}"}
            class={["ui-seg", @mode == mode && "is-on"]}
            aria-pressed={to_string(@mode == mode)}
            phx-click="mode"
            phx-value-mode={mode}
          >
            {label}
          </button>
        </nav>

        <%!-- Always there, one line high: an error never pushes the controls down --%>
        <p class="ui-pendant-msg" id="pendant-msg" role="status" aria-live="polite">
          <span :if={@error} id="pendant-error">{@error}</span>
        </p>

        <div class={"ui-pendant-body is-#{@mode}"} id="pendant-body">
          <%= case @mode do %>
            <% :jog -> %>
              <.jog_mode machine={@shell_machine} tier={@tier} tiers={@tiers} />
            <% :inc -> %>
              <.inc_mode machine={@shell_machine} axis={@step_axis} step={@step} steps={@steps} />
            <% :zero -> %>
              <.zero_mode machine={@shell_machine} undo={@undo_zero} />
            <% :job -> %>
              <.job_mode machine={@shell_machine} program={@program} />
          <% end %>
        </div>

        <footer class="ui-pendant-foot">
          <.link navigate={~p"/"} class="ui-pendant-back" id="pendant-workstation">
            Open the workstation
          </.link>
        </footer>
      </div>

      <UI.dialog
        :if={@start_check? and @program}
        id="pendant-start-dialog"
        title={"Start #{@program.name}?"}
        on_cancel="cancel_start"
      >
        <ul class="cnc-checks">
          <li class={[
            "cnc-check-item",
            fit(@program, @shell_machine) == [] && "is-ok",
            fit(@program, @shell_machine) != [] && "is-bad"
          ]}>
            <.icon
              name={
                if(fit(@program, @shell_machine) == [],
                  do: "hero-check-circle",
                  else: "hero-x-circle"
                )
              }
              class="cnc-check-icon"
            />
            <span>{fit_text(fit(@program, @shell_machine))}</span>
          </li>
          <li class="cnc-check-item">
            <.icon name="hero-hand-raised" class="cnc-check-icon" />
            <span>Stock clamped, spindle on and up to speed, hands and cables clear.</span>
          </li>
        </ul>
        <p class="ui-muted">
          Dry run, Check and Outline are on the workstation.
        </p>
        <:actions>
          <UI.button variant="quiet" id="pendant-cancel-start" phx-click="cancel_start">
            Not yet
          </UI.button>
          <UI.button
            variant="primary"
            id="pendant-confirm-start"
            phx-click="confirm_start"
            disabled={fit(@program, @shell_machine) != []}
          >
            <.icon name="hero-play" class="ui-btn-icon" /> Start cutting
          </UI.button>
        </:actions>
      </UI.dialog>

      <UI.dialog
        :if={@abort_check? and @shell_machine.job}
        id="pendant-abort-dialog"
        title="Abort the job?"
        on_cancel="cancel_abort"
      >
        <p class="ui-muted">
          The machine stops at once and comes back locked. The work zero is kept.
        </p>
        <:actions>
          <UI.button id="pendant-cancel-abort" phx-click="cancel_abort">Keep running</UI.button>
          <UI.button variant="danger" id="pendant-confirm-abort" phx-click="confirm_abort">
            Abort
          </UI.button>
        </:actions>
      </UI.dialog>
    </Layouts.pendant>
    """
  end

  ## Modes

  attr :machine, :map, required: true
  attr :tier, :atom, required: true
  attr :tiers, :list, required: true

  defp jog_mode(assigns) do
    ~H"""
    <.speed tier={@tier} tiers={@tiers} />
    <%!-- The stick, and over it (only when it can't jog) why not and what to press --%>
    <div class="ui-pendant-stage">
      <div :if={cover(@machine)} class="ui-pendant-cover" id={"pendant-" <> elem(cover(@machine), 0)}>
        <p class={"ui-pendant-cover-msg is-#{elem(cover(@machine), 1)}"}>
          {elem(cover(@machine), 2)}
        </p>
      </div>
      <div
        id="pendant-joystick"
        class="cnc-joy ui-pendant-joy"
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
    """
  end

  attr :tier, :atom, required: true
  attr :tiers, :list, required: true

  defp speed(assigns) do
    ~H"""
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
    """
  end

  attr :machine, :map, required: true
  attr :axis, :atom, required: true
  attr :step, :any, required: true
  attr :steps, :list, required: true

  defp inc_mode(assigns) do
    assigns = assign(assigns, ready?: assigns.machine.state == :idle)

    ~H"""
    <div class="ui-pendant-inc" id="pendant-inc">
      <p :if={not @ready?} class="cnc-mode-off">{off_text(@machine)}</p>
      <div class="ui-pendant-row" role="group" aria-label="Axis">
        <button
          :for={a <- [:x, :y, :z]}
          type="button"
          id={"pendant-axis-#{a}"}
          class={["ui-seg", "ui-axis-#{a}", @axis == a && "is-on"]}
          aria-pressed={to_string(@axis == a)}
          phx-click="step_axis"
          phx-value-axis={a}
        >
          {a |> to_string() |> String.upcase()}
        </button>
      </div>
      <div class="ui-pendant-row" role="group" aria-label="Step in mm">
        <button
          :for={mm <- @steps}
          type="button"
          id={"pendant-step-#{mm}"}
          class={["ui-seg num", @step == mm && "is-on"]}
          aria-pressed={to_string(@step == mm)}
          phx-click="step_size"
          phx-value-mm={mm}
        >
          {mm}
        </button>
      </div>
      <div class="ui-pendant-go">
        <button
          :for={{dir, sign} <- [{-1, "−"}, {1, "+"}]}
          type="button"
          id={"pendant-step-#{if dir < 0, do: "minus", else: "plus"}"}
          class={["ui-pendant-big", "ui-axis-#{@axis}"]}
          phx-click="step"
          phx-value-dir={dir}
          disabled={not @ready?}
          aria-label={"Move #{String.upcase(to_string(@axis))} #{sign} #{@step} mm"}
        >
          <span>{String.upcase(to_string(@axis))}{sign}</span>
          <span class="ui-seg-unit num">{@step} mm</span>
        </button>
      </div>
    </div>
    """
  end

  attr :machine, :map, required: true
  attr :undo, :any, required: true

  defp zero_mode(assigns) do
    assigns = assign(assigns, ready?: assigns.machine.state == :idle)

    ~H"""
    <div class="ui-pendant-zero" id="pendant-zero">
      <p :if={not @ready?} class="cnc-mode-off">{off_text(@machine)}</p>
      <p class="ui-muted">
        Zero X/Y at the stock's corner, Zero Z on its surface. Zeroing doesn't move anything.
      </p>
      <div class="ui-pendant-go">
        <button
          type="button"
          id="pendant-zero-xy"
          class="ui-pendant-big"
          phx-click="zero"
          phx-value-axes="xy"
          disabled={not @ready?}
        >
          <span>Zero X/Y</span>
        </button>
        <button
          type="button"
          id="pendant-zero-z"
          class="ui-pendant-big ui-axis-z"
          phx-click="zero"
          phx-value-axes="z"
          disabled={not @ready?}
        >
          <span>Zero Z</span>
        </button>
      </div>
      <%!-- Always there (disabled when there's nothing to undo): no shift --%>
      <button
        type="button"
        id="pendant-undo-zero"
        class="ui-btn ui-btn--secondary ui-btn--lg"
        phx-click="undo_zero"
        disabled={@undo == nil or not @ready?}
      >
        Undo the last zero
      </button>
      <button
        type="button"
        id="pendant-go-zero"
        class="ui-btn ui-btn--secondary ui-btn--lg"
        phx-click="go_to_zero"
        disabled={not @ready?}
        title="Moves the machine: rapid to X0 Y0 at a safe height"
      >
        <.icon name="hero-arrow-down-left" class="ui-btn-icon" /> Go to X0 Y0
      </button>
    </div>
    """
  end

  attr :machine, :map, required: true
  attr :program, :any, required: true

  defp job_mode(%{machine: %{job: job}} = assigns) when job != nil do
    pct = round(fraction(job, assigns.machine) * 100)
    elapsed = DateTime.diff(DateTime.utc_now(), job.started_at)
    {feed_ov, rapid_ov, _} = assigns.machine.overrides || {100, 100, 100}
    left = time_left(pct / 100, elapsed, assigns.program, feed_ov)

    assigns =
      assign(assigns, pct: pct, left: left, feed_ov: feed_ov, rapid_ov: rapid_ov, job: job)

    ~H"""
    <section class="ui-pendant-job" id="pendant-job" aria-label="Job">
      <div class="cnc-job-head">
        <p class="cnc-file-name">{@job.name}</p>
        <span class="cnc-job-pct num">{@pct}%</span>
      </div>
      <div class="cnc-job-bar" role="progressbar" aria-valuenow={@pct} aria-label="Progress">
        <span style={"width: #{@pct}%"}></span>
      </div>
      <p class="ui-muted num">{if @left, do: "about #{duration(@left)} left", else: " "}</p>
      <p :if={match?({:dry, _}, @job.mode)} class="cnc-dry">
        Dry run: Z lifted {elem(@job.mode, 1)} mm, spindle left off
      </p>
      <p class="ui-pendant-label">Feed</p>
      <div class="ui-pendant-row" role="group" aria-label="Feed">
        <button
          :for={{op, label} <- [{"minus10", "−10%"}, {"reset", "#{@feed_ov}%"}, {"plus10", "+10%"}]}
          type="button"
          class={["ui-seg num", op == "reset" && @feed_ov == 100 && "is-on"]}
          id={"pendant-ov-#{String.replace(op, "10", "")}"}
          phx-click="feed_override"
          phx-value-op={op}
          title={if op == "reset", do: "Back to 100%"}
        >
          {label}
        </button>
      </div>
      <p class="ui-pendant-label">Rapids</p>
      <div class="ui-pendant-row" role="group" aria-label="Rapids">
        <button
          :for={p <- [25, 50, 100]}
          type="button"
          class={["ui-seg num", @rapid_ov == p && "is-on"]}
          id={"pendant-rapid-#{p}"}
          phx-click="rapid_override"
          phx-value-percent={p}
        >
          {p}%
        </button>
      </div>
      <p class="ui-pendant-label">Single block</p>
      <div class="ui-pendant-row" role="group" aria-label="Single block">
        <button
          :for={{on?, label} <- [{false, "Off"}, {true, "On"}]}
          type="button"
          class={["ui-seg", @job.single_block? == on? && "is-on"]}
          id={"pendant-single-#{on?}"}
          phx-click="single_block"
          phx-value-on={to_string(on?)}
        >
          {label}
        </button>
      </div>
      <p :if={@job.waiting?} class="cnc-note" id="pendant-next">
        Line {elem(@job.next, 0)} is next ({elem(@job.next, 1)}): press Next line.
      </p>
      <button
        type="button"
        id="pendant-abort"
        class="ui-btn ui-btn--secondary ui-btn--lg cnc-abort"
        phx-click="abort_job"
      >
        Abort the job
      </button>
    </section>
    """
  end

  defp job_mode(assigns) do
    ~H"""
    <section class="ui-pendant-job" id="pendant-job" aria-label="Job">
      <%= if @program do %>
        <p class="cnc-file-name">{@program.name}</p>
        <p class="ui-muted">
          {fit_text(fit(@program, @machine))}
        </p>
        <button
          type="button"
          id="pendant-start"
          class="ui-btn ui-btn--primary ui-btn--lg"
          phx-click="start_check"
          disabled={@machine.state != :idle}
        >
          <.icon name="hero-play" class="ui-btn-icon" /> Start…
        </button>
      <% else %>
        <div class="cnc-program-empty" id="pendant-no-file">
          <.icon name="hero-document" class="cnc-program-empty-icon" />
          <p>No file loaded.</p>
          <p class="cnc-sub">Open one on the workstation.</p>
        </div>
      <% end %>
    </section>
    """
  end

  ## What the cycle button does now

  defp cycle(%{state: :alarm}, _program), do: :unlock
  defp cycle(%{state: s, controller: :hold}, _program) when s in [:busy, :running], do: :resume
  defp cycle(%{state: :running, job: %{waiting?: true}}, _program), do: :next
  defp cycle(%{state: :idle}, %Program{}), do: :start
  defp cycle(_, _), do: nil

  defp cycle_label(m, p) do
    case cycle(m, p) do
      :unlock -> "Unlock"
      :resume -> "Resume"
      :next -> "Next line"
      _ -> "Start"
    end
  end

  defp cycle_icon(m, p), do: if(cycle(m, p) == :unlock, do: "hero-lock-open", else: "hero-play")

  # Over the stick when it can't jog: {id, tone, message}
  defp cover(%{state: :alarm}),
    do: {"locked", "danger", "Locked: the position isn't confirmed. Press Unlock to jog."}

  defp cover(%{state: s, controller: :hold}) when s in [:busy, :running],
    do: {"held", "warn", "On hold: motion paused, position kept. Press Resume to carry on."}

  defp cover(%{state: s, controller: :door}) when s in [:busy, :running],
    do: {"door", "warn", "Door open: close it, then press Resume."}

  defp cover(%{state: :running}),
    do: {"running", "neutral", "A job is running: jogging is off. Watch it under Job."}

  defp cover(%{state: s}) when s in [:disconnected, :connecting],
    do: {"offline", "neutral", "#{UI.state_word(s)}: no controller to jog."}

  defp cover(_), do: nil

  defp off_text(%{state: :running}), do: "A job is running: this is off until it ends."
  defp off_text(%{state: :alarm}), do: "Locked: press Unlock first."
  defp off_text(%{state: s}) when s in [:disconnected, :connecting], do: "No controller."
  defp off_text(_), do: "Wait for the machine to be Ready."

  defp fit_text([]), do: "Fits the travel from the work zero."
  defp fit_text(:no_work_zero), do: "The controller hasn't reported a work zero yet."
  defp fit_text(issues), do: "Won't fit: " <> Enum.map_join(issues, " ", &fit_issue/1)

  defp zero_error(:moving), do: "Wait for the machine to stop."
  defp zero_error(:outside_travel), do: "That's outside the travel."
  defp zero_error(:no_work_offset), do: "The controller hasn't reported a work zero yet."
  defp zero_error({:invalid_state, _}), do: "Only when the machine is Ready."
  defp zero_error(other), do: "Couldn't: #{inspect(other)}"

  defp send_to(socket, fun) do
    fun.(machine(socket))
    {:noreply, socket}
  end

  defp machine(socket), do: socket.assigns.cnc.machine

  # Work position, two decimals (as the machine screen shows it).
  defp position(%{wpos: {x, y, z}}), do: [x: fmt(x), y: fmt(y), z: fmt(z)]
  defp position(_), do: [x: "–", y: "–", z: "–"]

  defp fmt(v) when is_number(v), do: :erlang.float_to_binary(v * 1.0, decimals: 2)
  defp fmt(_), do: "–"
end
