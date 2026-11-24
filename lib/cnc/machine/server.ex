defmodule CNC.Machine.Server do
  @moduledoc """
  `gen_statem` behind `CNC.Machine`. The only process that talks to the
  transport.

  ## States

      :disconnected ─(transport started)─▶ :connecting ─(first status)─▶ :alarm
      :alarm ─($X ok)─▶ :idle ◀─▶ :jogging
      :alarm | :idle ─($H)─▶ :homing ─(ok)─▶ :idle
      :idle | :jogging ─(status: hold/door/...)─▶ :busy ─(status: Idle)─▶ :idle
      any ─(ALARM:N or status Alarm)─▶ :alarm
      any ─(banner = controller reset)─▶ :connecting
      any ─(transport lost)─▶ :disconnected ─(backoff)─▶ reconnect

  Every (re)connect and reset lands in `:alarm`: even if the controller says
  Idle, the host requires an explicit Unlock or Home before moving.

  State changes are driven by what the controller reports (status, acks,
  alarms), never by what we commanded, except `:jogging`, which is the host's
  jog session (held keys + dead-man).
  """
  @behaviour :gen_statem
  require Logger

  alias CNC.Grbl.{Command, Realtime, Response, Status}
  alias CNC.Machine.{Console, Jog, State}

  @poll_ms 200
  @poll_jog_ms 50
  @deadman_ms 250
  # No status report for this long means the link is dead even if the socket
  # or port looks open. Longer while connecting: an ESP32 may reboot when the
  # USB port opens and needs a few seconds to boot.
  @watchdog_ms 1_500
  @connect_watchdog_ms 6_000
  @publish_ms 50
  @backoff_min 100
  @backoff_max 5_000

  defstruct [
    :adapter,
    :adapter_opts,
    :travel,
    :config_travel,
    :config_max_rate,
    :transport,
    :pubsub,
    :topic,
    :status,
    :alarm,
    :last_error,
    :target,
    :published,
    :published_at,
    :watchdog_ms,
    :connect_watchdog_ms,
    connected?: false,
    # A motion line was sent since the last status that followed all acks:
    # the reported position may not reflect it yet.
    motion_unsettled?: false,
    status_at: nil,
    # Unit vector of the last movement between two reports, to split the
    # controller's path feed (FS) into X/Y and Z speeds.
    direction: {0.0, 0.0, 0.0},
    # $$ is only accepted when the controller is Idle or in Alarm: ask once
    # it is (and again if it said error:8, busy).
    settings_wanted?: false,
    # Build info ($I) and the boot banner: what's on the other end. Info
    # lines collect in info_partial and become info when $I is acked, so a
    # half-received reply is never published.
    info: %{},
    info_partial: %{},
    banner: nil,
    # Bumped whenever a settings read completes, so pages know to refresh.
    settings_rev: 0,
    # Results of the last write_settings: %{n => :pending | :ok | {:error, code}}
    settings_write: %{},
    tier: :normal,
    vector: {0, 0, 0},
    in_flight: 0,
    # Set by a stop until the controller is idle with nothing unacked. FluidNC
    # ignores a jog cancel unless it's already in Jog, and doesn't discard
    # jog lines it hasn't parsed yet: a line can run after the cancel.
    # While stopping, any sign of one (a jog ack, a Jog report) cancels again.
    stopping?: false,
    pending: :queue.new(),
    console: Console.new(),
    settings: %{},
    travel_source: :config,
    travel_issues: [],
    backoff: 0
  ]

  def child_spec(opts),
    do: %{id: CNC.Machine, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    case Keyword.get(opts, :name, CNC.Machine) do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> :gen_statem.start_link({:local, name}, __MODULE__, opts, [])
    end
  end

  @impl :gen_statem
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl :gen_statem
  def init(opts) do
    Process.flag(:trap_exit, true)

    machine = Application.get_env(:cnc, :machine, [])
    travel = Keyword.get_lazy(opts, :travel, fn -> Keyword.fetch!(machine, :travel) end)

    max_rate =
      Keyword.get_lazy(opts, :max_rate, fn ->
        Keyword.get(machine, :max_rate, {3000.0, 3000.0, 1200.0})
      end)

    {adapter, adapter_opts} =
      Keyword.get_lazy(opts, :transport, fn ->
        config = Application.fetch_env!(:cnc, :transport)
        {Keyword.fetch!(config, :adapter), Keyword.get(config, :opts, [])}
      end)

    {:ok, :disconnected,
     %__MODULE__{
       adapter: adapter,
       adapter_opts: adapter_opts,
       travel: travel,
       config_travel: travel,
       config_max_rate: max_rate,
       pubsub: Keyword.get(opts, :pubsub, CNC.PubSub),
       topic: Keyword.get(opts, :topic, "machine"),
       watchdog_ms: Keyword.get(opts, :watchdog_ms, @watchdog_ms),
       connect_watchdog_ms: Keyword.get(opts, :connect_watchdog_ms, @connect_watchdog_ms)
     }}
  end

  # Every event goes through event/4, which returns {state, data, actions};
  # we then publish the resulting snapshot (throttled) in one place.
  @impl :gen_statem
  def handle_event(type, content, state, data) do
    {next, data, actions} = event(type, content, state, data)
    {data, publish} = publish(next, data)

    if type == :enter,
      do: {:keep_state, data, actions ++ publish},
      else: {:next_state, next, data, actions ++ publish}
  end

  ## State enter

  defp event(:enter, _old, :disconnected, d) do
    delay = d.backoff

    d = %{
      end_session(d)
      | transport: nil,
        connected?: false,
        status: nil,
        alarm: nil,
        pending: :queue.new(),
        in_flight: 0,
        settings: %{},
        settings_wanted?: false,
        info: %{},
        info_partial: %{},
        banner: nil,
        travel: d.config_travel,
        travel_source: :config,
        travel_issues: [],
        backoff: next_backoff(delay)
    }

    {:disconnected, d,
     [{:state_timeout, delay, :reconnect}, cancel(:poll), cancel(:jog_tick), cancel(:deadman)] ++
       [cancel(:watchdog)]}
  end

  defp event(:enter, _old, :jogging, d),
    do:
      {:jogging, d,
       [poll(@poll_jog_ms), {{:timeout, :jog_tick}, 0, :tick}, deadman(), watchdog(d, :jogging)]}

  # grblHAL doesn't answer status polls while homing: silence is expected.
  defp event(:enter, _old, :homing, d), do: {:homing, d, [poll(@poll_ms), cancel(:watchdog)]}

  defp event(:enter, :jogging, s, d),
    do: {s, end_session(d), [poll(@poll_ms), cancel(:jog_tick), cancel(:deadman), watchdog(d, s)]}

  defp event(:enter, _old, s, d), do: {s, d, [poll(@poll_ms), watchdog(d, s)]}

  ## Connection

  defp event(:state_timeout, :reconnect, :disconnected, d) do
    case d.adapter.start_link(self(), d.adapter_opts) do
      {:ok, pid} ->
        {:connecting, %{d | transport: pid}, []}

      {:error, reason} ->
        Logger.warning("transport start failed: #{inspect(reason)}")

        {:disconnected, %{d | backoff: next_backoff(d.backoff)},
         [{:state_timeout, d.backoff, :reconnect}]}
    end
  end

  defp event(:info, {:transport, :connected}, s, d), do: {s, %{d | connected?: true}, []}
  defp event(:info, {:transport, :disconnected}, _s, d), do: {:disconnected, d, []}
  defp event(:info, {:EXIT, pid, _}, _s, %{transport: pid} = d), do: {:disconnected, d, []}
  defp event(:info, {:EXIT, _stale, _}, s, d), do: {s, d, []}

  defp event(:info, {:transport, :line, line}, s, d) do
    parsed = Response.parse(line)
    status? = match?({:status, _}, parsed)

    {next, d, actions} =
      response(parsed, s, log(d, :in, if(status?, do: :poll, else: :line), line))

    # Every status report proves the link is alive.
    if status? and next not in [:disconnected, :homing],
      do: {next, d, [watchdog(d, next) | actions]},
      else: {next, d, actions}
  end

  ## Timers

  defp event({:timeout, :poll}, :poll, s, d) do
    d = if d.connected?, do: realtime(d, Realtime.status()), else: d
    {s, d, [poll(if s == :jogging or d.stopping?, do: @poll_jog_ms, else: @poll_ms)]}
  end

  defp event({:timeout, :jog_tick}, :tick, :jogging, d),
    do: {:jogging, top_up(d), [{{:timeout, :jog_tick}, Jog.dt_ms(), :tick}]}

  defp event({:timeout, :deadman}, :expired, :jogging, d) do
    d = realtime(d, Realtime.jog_cancel())
    {:idle, %{d | last_error: {:jog, :heartbeat_lost}, stopping?: true}, []}
  end

  defp event({:timeout, :watchdog}, :expired, s, d) when s not in [:disconnected, :homing] do
    Logger.warning("no status from the controller in #{s}; dropping the link and reconnecting")
    # Best effort: if the link is half-alive, stop any motion. close/1 runs
    # after the queued jog cancel; the timer is the backstop for a transport
    # that is itself hung.
    d = if d.connected?, do: realtime(d, Realtime.jog_cancel()), else: d
    :ok = d.adapter.close(d.transport)
    :timer.exit_after(1_000, d.transport, {:shutdown, :watchdog})
    {:disconnected, %{d | last_error: {:link, :no_response}}, []}
  end

  defp event({:timeout, _}, _, s, d), do: {s, d, []}

  ## Calls

  defp event({:call, from}, :status, s, d), do: {s, d, [{:reply, from, snapshot(s, d)}]}

  defp event({:call, from}, :console, s, d),
    do: {s, d, [{:reply, from, Console.to_list(d.console)}]}

  defp event({:call, from}, :unlock, s, d) when s in [:alarm, :idle],
    do: {s, send_line(d, Command.unlock(), :unlock), [{:reply, from, :ok}]}

  defp event({:call, from}, :home, s, d) when s in [:alarm, :idle],
    do: {:homing, send_line(d, Command.home(), :home), [{:reply, from, :ok}]}

  defp event({:call, from}, {:jog, {0, 0, 0}, _tier}, s, d),
    do: event({:call, from}, :jog_stop, s, d)

  defp event({:call, from}, {:jog, vector, tier}, :idle, d) do
    d = %{
      d
      | vector: vector,
        tier: tier,
        target: d.status.mpos,
        last_error: nil,
        stopping?: false
    }

    {:jogging, d, [{:reply, from, :ok}]}
  end

  defp event({:call, from}, {:jog, vector, tier}, :jogging, d),
    do: {:jogging, %{d | vector: vector, tier: tier}, [{:reply, from, :ok}, deadman()]}

  defp event({:call, from}, :jog_heartbeat, :jogging, d),
    do: {:jogging, d, [{:reply, from, :ok}, deadman()]}

  # Stopping is never refused.
  defp event({:call, from}, :jog_stop, s, d) do
    d = if d.connected?, do: realtime(d, Realtime.jog_cancel()), else: d
    d = if s == :jogging, do: %{d | stopping?: true}, else: d
    {if(s == :jogging, do: :idle, else: s), d, [{:reply, from, :ok}]}
  end

  defp event({:call, from}, {:jog_step, vector, mm}, :idle, d) do
    {delta, feed} = Jog.step(vector, mm, d.tier)
    delta = Jog.clamp(d.status.mpos, delta, d.travel)

    if Jog.zero?(delta),
      do: {:idle, d, [{:reply, from, {:error, :at_limit}}]},
      else: {:idle, send_line(d, Command.jog(delta, feed), :step), [{:reply, from, :ok}]}
  end

  # Terminal input. $X/$H/$$ take the same paths as the buttons so the host's
  # view can't drift; setting writes trigger a fresh $$. Typed motion is not
  # covered by the jog dead-man or the travel clamp (controller limits apply).
  defp event({:call, from}, {:raw, line}, s, d) when s in [:alarm, :idle, :busy] do
    case String.upcase(line) do
      # Real-time characters go out as bytes, unacked, like the buttons.
      "?" -> {s, realtime(d, Realtime.status()), [{:reply, from, :ok}]}
      "!" -> event({:call, from}, :feed_hold, s, d)
      "~" -> event({:call, from}, :resume, s, d)
      "$X" -> event({:call, from}, :unlock, s, d)
      "$H" -> event({:call, from}, :home, s, d)
      "$$" -> {s, send_line(d, line, :settings), [{:reply, from, :ok}]}
      "$" <> _ = upper -> {s, send_line(d, line, raw_tag(upper)), [{:reply, from, :ok}]}
      _ -> {s, send_line(d, line, :raw), [{:reply, from, :ok}]}
    end
  end

  defp event({:call, from}, :settings, s, d), do: {s, d, [{:reply, from, d.settings}]}

  defp event({:call, from}, {:write_settings, changes}, s, d) when s in [:idle, :alarm] do
    if d.motion_unsettled? or (d.status && d.status.state in [:run, :jog, :home]) do
      {s, d, [{:reply, from, {:error, :moving}}]}
    else
      d =
        Enum.reduce(changes, %{d | settings_write: %{}}, fn {n, value}, d ->
          d = send_line(d, "$#{n}=#{value}", {:setting, n})
          %{d | settings_write: Map.put(d.settings_write, n, :pending)}
        end)

      {s, d, [{:reply, from, :ok}]}
    end
  end

  defp event({:call, from}, {:work_zero, axes}, :idle, d) do
    line = Command.set_work(for axis <- axes, do: {axis, 0})
    {:idle, send_line(d, line, :raw), [{:reply, from, :ok}]}
  end

  # Lift Z to near the top of travel (never lower it), then move X/Y to the
  # work origin. Both are bounded jogs: Esc / jog cancel stops them.
  defp event({:call, from}, :go_to_work_zero, :idle, d) do
    case work_zero_moves(d) do
      {:ok, moves} ->
        d =
          Enum.reduce(moves, d, fn {delta, feed}, d ->
            send_line(d, Command.jog(delta, feed), :step)
          end)

        {:idle, d, [{:reply, from, :ok}]}

      {:error, _} = err ->
        {:idle, d, [{:reply, from, err}]}
    end
  end

  defp event({:call, from}, cmd, s, %{connected?: true} = d)
       when cmd in [:feed_hold, :resume, :reset] do
    byte =
      case cmd do
        :feed_hold -> Realtime.feed_hold()
        :resume -> Realtime.resume()
        :reset -> Realtime.reset()
      end

    d = realtime(d, byte)
    # Feed hold cancels an active jog on the controller.
    next = if cmd == :feed_hold and s == :jogging, do: :idle, else: s
    {next, d, [{:reply, from, :ok}]}
  end

  defp event({:call, from}, _request, s, d),
    do: {s, d, [{:reply, from, {:error, {:invalid_state, s}}}]}

  ## Controller responses

  # WCO only comes every few reports: carry the last one forward so work
  # positions don't flicker. It's dropped with the rest of the status on
  # reconnect or controller reset.
  defp response({:status, status}, s, d) do
    status = Status.with_wco(status, d.status && d.status.wco)
    prev_mpos = d.status && d.status.mpos
    # Output is ordered: a report after every ack reflects all sent motion.
    settled = if :queue.is_empty(d.pending), do: false, else: d.motion_unsettled?
    d = %{d | status: status, motion_unsettled?: settled, status_at: now()}
    d = %{d | direction: direction(d.direction, prev_mpos, status.mpos)}
    d = if s == :connecting, do: d, else: maybe_read_settings(d, status.state)
    on_status(s, status.state, d)
  end

  defp response(:ok, s, d), do: ack(:ok, s, d)
  defp response({:error, _} = err, s, d), do: ack(err, s, d)

  # The controller resets after an alarm and drops buffered lines: their acks
  # will never arrive.
  defp response({:alarm, code}, _s, d),
    do: {:alarm, %{flush_pending(d) | alarm: {:alarm, code}}, []}

  defp response({:setting, n, value}, s, d),
    do: {s, %{d | settings: Map.put(d.settings, n, value)}, []}

  defp response({:info, key, value}, s, d),
    do: {s, %{d | info_partial: Map.put(d.info_partial, key, value)}, []}

  defp response({:banner, banner}, s, d) when s in [:disconnected, :connecting],
    do: {s, %{d | banner: banner}, []}

  defp response({:banner, banner}, _s, d) do
    Logger.info("controller reset: #{banner}")
    {:connecting, %{flush_pending(d) | alarm: :reset, status: nil, banner: banner}, []}
  end

  defp response(other, s, d) do
    Logger.debug("controller: #{inspect(other)}")
    {s, d, []}
  end

  defp on_status(:disconnected, _, d), do: {:disconnected, d, []}

  # First report after (re)connect or reset. Never trust it enough to move:
  # lock until Unlock/Home. A jog left running by a previous session is stopped.
  defp on_status(:connecting, reported, d) do
    d = if reported == :jog, do: realtime(d, Realtime.jog_cancel()), else: d
    d = maybe_read_settings(%{d | settings_wanted?: true}, reported)
    {:alarm, %{d | alarm: d.alarm || :connect, backoff: 0}, []}
  end

  defp on_status(s, :alarm, d) when s != :alarm, do: {:alarm, %{d | alarm: :reported}, []}
  defp on_status(s, _, d) when s in [:alarm, :homing], do: {s, d, []}

  # Stopping: a Jog report means a line ran past the cancel; cancel again.
  # Idle with nothing unacked means it's over.
  defp on_status(:idle, :jog, %{stopping?: true} = d),
    do: {:idle, realtime(d, Realtime.jog_cancel()), []}

  defp on_status(:idle, :idle, %{stopping?: true, in_flight: 0} = d),
    do: {:idle, %{d | stopping?: false}, []}

  defp on_status(s, reported, d) when s in [:idle, :jogging] and reported in [:idle, :jog],
    do: {s, d, []}

  defp on_status(:jogging, _other, d) do
    {:busy, realtime(d, Realtime.jog_cancel()), []}
  end

  defp on_status(:idle, _other, d), do: {:busy, d, []}
  defp on_status(:busy, :idle, d), do: {:idle, d, []}
  defp on_status(s, _, d), do: {s, d, []}

  defp ack(result, s, d) do
    case :queue.out(d.pending) do
      {:empty, _} ->
        Logger.debug("unsolicited #{inspect(result)}")
        {s, d, []}

      {{:value, tag}, rest} ->
        in_flight = if tag == :jog, do: d.in_flight - 1, else: d.in_flight
        d = %{d | pending: rest, in_flight: in_flight}
        # A jog line planned after a stop's cancel: cancel it too.
        d = if tag == :jog and d.stopping?, do: realtime(d, Realtime.jog_cancel()), else: d
        on_ack(tag, result, s, d)
    end
  end

  defp on_ack(:settings, :ok, s, d),
    do: {s, %{apply_settings(d) | settings_rev: d.settings_rev + 1}, []}

  # One written setting answered. Once all have, read them back to verify.
  defp on_ack({:setting, n}, result, s, d) do
    write = Map.put(d.settings_write, n, result)
    done? = not Enum.any?(write, fn {_, r} -> r == :pending end)
    d = %{d | settings_write: write, settings_wanted?: d.settings_wanted? or done?}
    {s, maybe_read_settings(d, d.status && d.status.state), []}
  end

  defp on_ack(:raw_setting, :ok, s, d),
    do: {s, send_line(%{d | settings: %{}}, Command.settings(), :settings), []}

  # Not every controller knows $I; identification then relies on the banner.
  defp on_ack(:info, :ok, s, d), do: {s, %{d | info: d.info_partial}, []}
  defp on_ack(:info, _error, s, d), do: {s, d, []}

  # Busy (still moving): ask again once it reports Idle/Alarm.
  defp on_ack(:settings, {:error, 8}, s, d), do: {s, %{d | settings_wanted?: true}, []}

  defp on_ack(:settings, {:error, _} = err, s, d) do
    Logger.warning("controller rejected $$ (#{inspect(err)}); using configured travel")
    {s, d, []}
  end

  defp on_ack(:unlock, :ok, :alarm, d), do: {:idle, %{d | alarm: nil, last_error: nil}, []}
  defp on_ack(:home, :ok, :homing, d), do: {:idle, %{d | alarm: nil, last_error: nil}, []}
  defp on_ack(:home, {:error, _} = err, :homing, d), do: {:alarm, %{d | last_error: err}, []}

  # A rejected increment (e.g. error:15 soft limit) ends the session. Already
  # queued increments are within limits and run out on their own.
  defp on_ack(:jog, {:error, _} = err, :jogging, d), do: {:idle, %{d | last_error: err}, []}
  defp on_ack(_tag, {:error, _} = err, s, d), do: {s, %{d | last_error: err}, []}
  defp on_ack(_tag, :ok, s, d), do: {s, d, []}

  ## Settings

  # What's on the other end, from $I (VER/FIRMWARE/DRIVER), the boot banner,
  # and the transport (sims say so via CNC.Transport.simulated?/1).
  defp identify(%{info: info, banner: banner, adapter: adapter}) do
    ver = info["VER"] || ""
    text = ver <> " " <> (banner || "")

    firmware =
      cond do
        info["FIRMWARE"] -> info["FIRMWARE"]
        text =~ ~r/FluidNC/i -> "FluidNC"
        text =~ ~r/grblHAL/i -> "grblHAL"
        ver != "" or banner -> "Grbl"
        true -> nil
      end

    %{
      firmware: firmware,
      version: ver |> String.split(":") |> hd() |> blank_to_nil(),
      simulated?: CNC.Transport.simulated?(adapter) or info["DRIVER"] == "Simulator"
    }
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  # $22 is a bitmask in grblHAL (bit 0 = homing on); plain 0/1 in Grbl.
  # nil when the controller doesn't report it (e.g. FluidNC may not).
  defp homing_enabled?(%{22 => value}) do
    case Integer.parse(value) do
      {n, _} -> Bitwise.band(n, 1) == 1
      :error -> nil
    end
  end

  defp homing_enabled?(_settings), do: nil

  defp maybe_read_settings(%{settings_wanted?: true} = d, reported)
       when reported in [:idle, :alarm] do
    %{d | settings_wanted?: false, settings: %{}, info_partial: %{}}
    |> send_line(Command.settings(), :settings)
    |> send_line(Command.build_info(), :info)
  end

  defp maybe_read_settings(d, _reported), do: d

  # "$130=500" writes a setting; "$130" or "$G" just read.
  defp raw_tag(upper), do: if(String.contains?(upper, "="), do: :raw_setting, else: :raw)

  # Max travel $130-$132 are lengths. Mapped to ranges by convention: X/Y run
  # 0..length, Z runs -length..0 (origin front-left, Z zero at the top).
  #
  # The configured travel is the machine's physical maximum: the controller
  # may narrow it, never widen it. A wider axis is capped and reported in
  # travel_issues (e.g. a typo'd $130=12500). Anything missing or
  # non-positive keeps the configured travel.
  defp apply_settings(d) do
    lengths = for n <- 130..132, do: length_mm(d.settings[n])

    if Enum.all?(lengths, &is_float/1),
      do: use_controller_travel(d, lengths),
      else: incomplete(d)
  end

  defp incomplete(d) do
    Logger.warning("controller travel incomplete: #{inspect(d.settings)}")
    d
  end

  defp use_controller_travel(d, reported) do
    physical = physical_lengths(d.config_travel)

    {lengths, issues} =
      [:x, :y, :z]
      |> Enum.zip(Enum.zip(reported, physical))
      |> Enum.map_reduce([], fn {axis, {got, max}}, issues ->
        if got > max, do: {max, [{axis, got, max} | issues]}, else: {got, issues}
      end)

    if issues != [], do: Logger.warning("controller travel exceeds machine: #{inspect(issues)}")
    [x, y, z] = lengths

    %{
      d
      | travel: {{0.0, x}, {0.0, y}, {-z, 0.0}},
        travel_source: :controller,
        travel_issues: Enum.reverse(issues)
    }
  end

  defp physical_lengths({{x0, x1}, {y0, y1}, {z0, z1}}), do: [x1 - x0, y1 - y0, z1 - z0]

  defp length_mm(value) when is_binary(value) do
    case Float.parse(value) do
      {mm, _} when mm > 0 -> mm
      _ -> nil
    end
  end

  defp length_mm(_), do: nil

  ## Work coordinates

  defp work_zero_moves(%{status: %{wco: nil}}), do: {:error, :no_work_offset}

  # Moves are computed from the reported position, so it must be final.
  defp work_zero_moves(d) when d.motion_unsettled? or d.status.state in [:run, :jog, :home],
    do: {:error, :moving}

  defp work_zero_moves(%{status: %{mpos: {x, y, z}, wco: {wx, wy, _}}, travel: travel}) do
    {_, _, {_, z_top}} = travel
    safe_z = z_top - 1.0

    lift =
      if z < safe_z,
        do: [{{0.0, 0.0, Float.round(safe_z - z, 3)}, Jog.z_speed(:fast) * 60}],
        else: []

    from = {x, y, max(z, safe_z)}
    move = Jog.clamp(from, {wx - x, wy - y, 0.0}, travel)
    # The clamp stops a micron inside travel; a work zero on the edge (e.g.
    # at the machine origin) is fine. Further out than that, refuse.
    short = Jog.magnitude({wx - x - elem(move, 0), wy - y - elem(move, 1), 0.0})

    cond do
      short > 0.01 -> {:error, :outside_travel}
      Jog.zero?(move) -> {:ok, lift}
      true -> {:ok, lift ++ [{move, Jog.speed(:fast) * 60}]}
    end
  end

  ## Jogging

  # Each tick tops the controller up to the run-ahead bound. Sending just one
  # increment per tick matched the controller's consumption exactly, so any
  # timer lateness let it run dry: it dropped to Idle and braked between
  # increments (the UI showed Jog/Idle flicker; a real machine would stutter).
  defp top_up(d) do
    case maybe_increment(d) do
      ^d -> d
      d -> top_up(d)
    end
  end

  # Holding a key into a limit clamps the increment, so the tool slides up to
  # the edge (and along it on diagonals) and then just stops sending.
  defp maybe_increment(d) do
    {raw, feed} = Jog.increment(d.vector, d.tier)
    delta = Jog.clamp(d.target, raw, d.travel)

    # feed >= 1 mm/min: a barely-deflected stick shouldn't send F0.
    age = if d.status_at, do: now() - d.status_at, else: 0

    if not Jog.zero?(delta) and feed >= 1 and d.in_flight < Jog.max_in_flight() and
         Jog.room_ahead?(d.target, d.status.mpos, Jog.magnitude(raw), age) do
      %{send_line(d, Command.jog(delta, feed), :jog) | target: Jog.add(d.target, delta)}
    else
      d
    end
  end

  defp end_session(d), do: %{d | vector: {0, 0, 0}, target: nil}

  ## Transport

  defp send_line(d, line, tag) do
    :ok = d.adapter.write_line(d.transport, line)
    in_flight = if tag == :jog, do: d.in_flight + 1, else: d.in_flight
    moves? = tag in [:jog, :step, :raw]

    d = %{
      d
      | pending: :queue.in(tag, d.pending),
        in_flight: in_flight,
        motion_unsettled?: d.motion_unsettled? or moves?
    }

    log(d, :out, :line, IO.iodata_to_binary(line))
  end

  defp realtime(d, byte) do
    :ok = d.adapter.write_realtime(d.transport, byte)
    kind = if byte == Realtime.status(), do: :poll, else: :realtime
    log(d, :out, kind, Console.describe(byte))
  end

  # Console: polls go to their own topic so subscribers can opt out.
  defp log(d, dir, kind, text) do
    entry = Console.entry(dir, kind, text)
    topic = if kind == :poll, do: "#{d.topic}:console:polls", else: "#{d.topic}:console"
    Phoenix.PubSub.broadcast(d.pubsub, topic, {:machine_console, entry})
    %{d | console: Console.push(d.console, entry)}
  end

  defp flush_pending(d),
    do: %{end_session(d) | pending: :queue.new(), in_flight: 0, stopping?: false}

  ## Publishing (≤ 1 per @publish_ms; the latest snapshot always goes out)

  defp publish(s, d) do
    snap = snapshot(s, d)
    now = System.monotonic_time(:millisecond)

    cond do
      snap == d.published ->
        {d, []}

      d.published_at == nil or now - d.published_at >= @publish_ms ->
        Phoenix.PubSub.broadcast(d.pubsub, d.topic, {:machine, snap})
        {%{d | published: snap, published_at: now}, [cancel(:publish)]}

      true ->
        {d, [{{:timeout, :publish}, @publish_ms - (now - d.published_at), :publish}]}
    end
  end

  defp snapshot(s, d) do
    %State{
      state: s,
      connected?: d.connected? and s != :disconnected,
      adapter: d.adapter |> Module.split() |> List.last(),
      controller: d.status && d.status.state,
      substate: d.status && d.status.substate,
      mpos: d.status && d.status.mpos,
      wpos: d.status && d.status.wpos,
      wco: d.status && d.status.wco,
      feed: d.status && d.status.feed,
      speed: speed(d),
      max_rate: max_rate(d),
      buffer: d.status && d.status.buffer,
      awaiting_ack: :queue.len(d.pending),
      moving?: d.motion_unsettled? or (d.status != nil and d.status.state in [:run, :jog, :home]),
      alarm: d.alarm,
      last_error: d.last_error,
      tier: d.tier,
      jog: d.vector,
      travel: d.travel,
      travel_source: d.travel_source,
      travel_issues: d.travel_issues,
      homing_enabled?: homing_enabled?(d.settings),
      controller_info: identify(d),
      settings_rev: d.settings_rev,
      settings_write: d.settings_write
    }
  end

  ## Speed

  # Direction of travel between two reports; kept when the tool hasn't moved
  # measurably (reports can be closer together than a step).
  defp direction(dir, nil, _), do: dir
  defp direction(dir, _, nil), do: dir

  defp direction(dir, {x0, y0, z0}, {x1, y1, z1}) do
    {dx, dy, dz} = {x1 - x0, y1 - y0, z1 - z0}
    len = :math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1.0e-6, do: dir, else: {dx / len, dy / len, dz / len}
  end

  # The controller reports one feed for the whole path (FS, mm/min, all axes
  # together). Split along the direction of travel: X/Y is the speed across
  # the bed (the hypotenuse of X and Y), Z the vertical speed.
  defp speed(%{status: %{feed: feed}, direction: {ux, uy, uz}}) when is_number(feed) and feed > 0,
    do: {feed * :math.sqrt(ux * ux + uy * uy), feed * abs(uz)}

  defp speed(_), do: {0.0, 0.0}

  # Max rates in mm/min: the controller's $110-$112 when it reports them,
  # else the configured machine maximum.
  defp max_rate(d) do
    {cx, cy, cz} = d.config_max_rate

    {rate(d.settings[110], cx), rate(d.settings[111], cy), rate(d.settings[112], cz)}
  end

  defp rate(nil, fallback), do: fallback

  defp rate(value, fallback) do
    case Float.parse(value) do
      {mm_min, _} when mm_min > 0 -> mm_min
      _ -> fallback
    end
  end

  ## Helpers

  defp poll(ms), do: {{:timeout, :poll}, ms, :poll}
  defp now, do: System.monotonic_time(:millisecond)

  defp deadman, do: {{:timeout, :deadman}, @deadman_ms, :expired}

  defp watchdog(d, :connecting), do: {{:timeout, :watchdog}, d.connect_watchdog_ms, :expired}
  defp watchdog(d, _state), do: {{:timeout, :watchdog}, d.watchdog_ms, :expired}
  defp cancel(name), do: {{:timeout, name}, :cancel}

  # d.backoff is the reconnect delay to use next: 0 at start and after a good
  # session, then 100 ms doubling to 5 s while connects keep failing.
  defp next_backoff(0), do: @backoff_min
  defp next_backoff(ms), do: min(ms * 2, @backoff_max)
end
