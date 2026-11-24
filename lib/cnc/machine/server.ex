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

  alias CNC.Grbl.{Command, Realtime, Response}
  alias CNC.Machine.{Console, Jog, State}

  @poll_ms 200
  @poll_jog_ms 50
  @deadman_ms 250
  @publish_ms 50
  @backoff_min 100
  @backoff_max 5_000

  defstruct [
    :adapter,
    :adapter_opts,
    :travel,
    :config_travel,
    :transport,
    :pubsub,
    :topic,
    :status,
    :alarm,
    :last_error,
    :target,
    :published,
    :published_at,
    connected?: false,
    tier: :normal,
    vector: {0, 0},
    in_flight: 0,
    pending: :queue.new(),
    console: Console.new(),
    settings: %{},
    travel_source: :config,
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

    travel =
      Keyword.get_lazy(opts, :travel, fn -> Application.fetch_env!(:cnc, :machine)[:travel] end)

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
       pubsub: Keyword.get(opts, :pubsub, CNC.PubSub),
       topic: Keyword.get(opts, :topic, "machine")
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
        travel: d.config_travel,
        travel_source: :config,
        backoff: next_backoff(delay)
    }

    {:disconnected, d,
     [{:state_timeout, delay, :reconnect}, cancel(:poll), cancel(:jog_tick), cancel(:deadman)]}
  end

  defp event(:enter, _old, :jogging, d),
    do: {:jogging, d, [poll(@poll_jog_ms), {{:timeout, :jog_tick}, 0, :tick}, deadman()]}

  defp event(:enter, :jogging, s, d),
    do: {s, end_session(d), [poll(@poll_ms), cancel(:jog_tick), cancel(:deadman)]}

  defp event(:enter, _old, s, d), do: {s, d, [poll(@poll_ms)]}

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
    kind = if match?({:status, _}, parsed), do: :poll, else: :line
    response(parsed, s, log(d, :in, kind, line))
  end

  ## Timers

  defp event({:timeout, :poll}, :poll, s, d) do
    d = if d.connected?, do: realtime(d, Realtime.status()), else: d
    {s, d, [poll(if s == :jogging, do: @poll_jog_ms, else: @poll_ms)]}
  end

  defp event({:timeout, :jog_tick}, :tick, :jogging, d),
    do: {:jogging, maybe_increment(d), [{{:timeout, :jog_tick}, Jog.dt_ms(), :tick}]}

  defp event({:timeout, :deadman}, :expired, :jogging, d) do
    d = realtime(d, Realtime.jog_cancel())
    {:idle, %{d | last_error: {:jog, :heartbeat_lost}}, []}
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

  defp event({:call, from}, {:jog, {0, 0}, _tier}, s, d),
    do: event({:call, from}, :jog_stop, s, d)

  defp event({:call, from}, {:jog, vector, tier}, :idle, d) do
    d = %{d | vector: vector, tier: tier, target: d.status.mpos, last_error: nil}
    {:jogging, d, [{:reply, from, :ok}]}
  end

  defp event({:call, from}, {:jog, vector, tier}, :jogging, d),
    do: {:jogging, %{d | vector: vector, tier: tier}, [{:reply, from, :ok}, deadman()]}

  defp event({:call, from}, :jog_heartbeat, :jogging, d),
    do: {:jogging, d, [{:reply, from, :ok}, deadman()]}

  # Stopping is never refused.
  defp event({:call, from}, :jog_stop, s, d) do
    d = if d.connected?, do: realtime(d, Realtime.jog_cancel()), else: d
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

  defp response({:status, status}, s, d), do: on_status(s, status.state, %{d | status: status})
  defp response(:ok, s, d), do: ack(:ok, s, d)
  defp response({:error, _} = err, s, d), do: ack(err, s, d)

  # The controller resets after an alarm and drops buffered lines: their acks
  # will never arrive.
  defp response({:alarm, code}, _s, d),
    do: {:alarm, %{flush_pending(d) | alarm: {:alarm, code}}, []}

  defp response({:setting, n, value}, s, d),
    do: {s, %{d | settings: Map.put(d.settings, n, value)}, []}

  defp response({:banner, _}, s, d) when s in [:disconnected, :connecting], do: {s, d, []}

  defp response({:banner, banner}, _s, d) do
    Logger.info("controller reset: #{banner}")
    {:connecting, %{flush_pending(d) | alarm: :reset, status: nil}, []}
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
    d = send_line(%{d | settings: %{}}, Command.settings(), :settings)
    {:alarm, %{d | alarm: d.alarm || :connect, backoff: 0}, []}
  end

  defp on_status(s, :alarm, d) when s != :alarm, do: {:alarm, %{d | alarm: :reported}, []}
  defp on_status(s, _, d) when s in [:alarm, :homing], do: {s, d, []}

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
        on_ack(tag, result, s, %{d | pending: rest, in_flight: in_flight})
    end
  end

  defp on_ack(:settings, :ok, s, d), do: {s, apply_settings(d), []}

  defp on_ack(:raw_setting, :ok, s, d),
    do: {s, send_line(%{d | settings: %{}}, Command.settings(), :settings), []}

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

  # "$130=500" writes a setting; "$130" or "$G" just read.
  defp raw_tag(upper), do: if(String.contains?(upper, "="), do: :raw_setting, else: :raw)

  # Max travel $130-$132 are lengths. Mapped to ranges by convention: X/Y run
  # 0..length, Z runs -length..0 (origin front-left, Z zero at the top).
  # Anything missing or non-positive keeps the configured travel.
  defp apply_settings(d) do
    lengths = for n <- 130..132, do: length_mm(d.settings[n])

    case lengths do
      [x, y, z] when is_float(x) and is_float(y) and is_float(z) ->
        %{d | travel: {{0.0, x}, {0.0, y}, {-z, 0.0}}, travel_source: :controller}

      _ ->
        Logger.warning("controller travel incomplete: #{inspect(d.settings)}")
        d
    end
  end

  defp length_mm(value) when is_binary(value) do
    case Float.parse(value) do
      {mm, _} when mm > 0 -> mm
      _ -> nil
    end
  end

  defp length_mm(_), do: nil

  ## Jogging

  # Holding a key into a limit clamps the increment, so the tool slides up to
  # the edge (and along it on diagonals) and then just stops sending.
  defp maybe_increment(d) do
    {delta, feed} = Jog.increment(d.vector, d.tier)
    delta = Jog.clamp(d.target, delta, d.travel)

    if not Jog.zero?(delta) and d.in_flight < Jog.max_in_flight() and
         Jog.room_ahead?(d.target, d.status.mpos, d.tier) do
      %{send_line(d, Command.jog(delta, feed), :jog) | target: Jog.add(d.target, delta)}
    else
      d
    end
  end

  defp end_session(d), do: %{d | vector: {0, 0}, target: nil}

  ## Transport

  defp send_line(d, line, tag) do
    :ok = d.adapter.write_line(d.transport, line)
    in_flight = if tag == :jog, do: d.in_flight + 1, else: d.in_flight
    d = %{d | pending: :queue.in(tag, d.pending), in_flight: in_flight}
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

  defp flush_pending(d), do: %{end_session(d) | pending: :queue.new(), in_flight: 0}

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
      buffer: d.status && d.status.buffer,
      awaiting_ack: :queue.len(d.pending),
      alarm: d.alarm,
      last_error: d.last_error,
      tier: d.tier,
      jog: d.vector,
      travel: d.travel,
      travel_source: d.travel_source
    }
  end

  ## Helpers

  defp poll(ms), do: {{:timeout, :poll}, ms, :poll}
  defp deadman, do: {{:timeout, :deadman}, @deadman_ms, :expired}
  defp cancel(name), do: {{:timeout, name}, :cancel}

  # d.backoff is the reconnect delay to use next: 0 at start and after a good
  # session, then 100 ms doubling to 5 s while connects keep failing.
  defp next_backoff(0), do: @backoff_min
  defp next_backoff(ms), do: min(ms * 2, @backoff_max)
end
