defmodule CNC.Motion.Sim.Model do
  @moduledoc """
  Pure model of a small Grbl-ish controller: the functional core of
  `CNC.Motion.Sim`. Every function returns `{model, lines}`, where `lines`
  are the controller's replies (no newlines). Time only moves via
  `advance/2`, so tests are deterministic.

  Deliberately not a faithful firmware: constant velocity (no acceleration),
  jog-only motion, relative metric jogs only (`$J=G91 G21 ...`).

  Fidelity notes (Grbl 1.1 behaviour it does mirror):
    * boots into `Alarm`; `$X`/`$H` allowed from `Alarm` or `Idle`, else `error:8`
    * `$J=` only from `Idle`/`Jog` (`error:8`); target outside travel → `error:15`
    * feed hold (`!`) during a jog cancels it, like jog cancel (`0x85`)
    * `$H` acks `ok` only when the cycle completes
    * soft reset while moving → `ALARM:3` (jog) / `ALARM:6` (homing)
  """

  alias CNC.Grbl.{Realtime, Status}

  @banner "Grbl 1.1h ['$' for help]"
  @locked "[MSG:'$H'|'$X' to unlock]"
  @planner_blocks 15

  @type xyz :: {float, float, float}
  @type t :: %__MODULE__{
          state: :alarm | :idle | :jog | :home,
          pos: xyz,
          queue: :queue.queue({xyz, float}),
          feed: float,
          travel: {{float, float}, {float, float}, {float, float}},
          max_feed: float,
          homing_ms: non_neg_integer,
          homing_left: number
        }

  defstruct state: :alarm,
            pos: {0.0, 0.0, 0.0},
            queue: :queue.new(),
            feed: 0.0,
            travel: {{0.0, 1250.0}, {0.0, 1250.0}, {-100.0, 0.0}},
            max_feed: 3000.0,
            homing_ms: 1000,
            homing_left: 0

  @doc "Options: `:travel`, `:max_feed` (mm/min), `:homing_ms`, `:pos`."
  def new(opts \\ []),
    do: struct!(__MODULE__, Keyword.take(opts, [:travel, :max_feed, :homing_ms, :pos]))

  @doc "Lines a controller prints on power-up."
  def boot(m), do: {m, [@banner, @locked]}

  @doc "True while time matters (motion or homing in progress)."
  def busy?(%__MODULE__{state: s}), do: s in [:jog, :home]

  ## Line commands

  def line(%{state: s} = m, "$X") when s in [:alarm, :idle] do
    msg = if s == :alarm, do: ["[MSG:Caution: Unlocked]"], else: []
    {%{m | state: :idle}, msg ++ ["ok"]}
  end

  def line(%{state: s} = m, "$H") when s in [:alarm, :idle],
    do: {%{m | state: :home, homing_left: m.homing_ms}, []}

  def line(m, "$" <> cmd) when cmd in ["X", "H"], do: {m, ["error:8"]}

  def line(%{state: s} = m, "$J=" <> words) when s in [:idle, :jog] do
    with {:ok, delta, feed} <- parse_jog(words),
         target = add(tail(m), delta),
         :ok <- within_travel(target, m.travel) do
      queue = :queue.in({target, min(feed, m.max_feed)}, m.queue)
      {%{m | state: :jog, queue: queue}, ["ok"]}
    else
      {:error, code} -> {m, ["error:#{code}"]}
    end
  end

  def line(m, "$J=" <> _), do: {m, ["error:8"]}
  def line(m, _), do: {m, ["error:20"]}

  ## Real-time bytes

  def realtime(m, byte) do
    cond do
      byte == Realtime.status() -> {m, [status_line(m)]}
      byte in [Realtime.jog_cancel(), Realtime.feed_hold()] -> {cancel_jog(m), []}
      byte == Realtime.resume() -> {m, []}
      byte == Realtime.reset() -> reset(m)
      true -> {m, []}
    end
  end

  @doc "Raise an alarm (test hook): stops motion, enters `Alarm`."
  def alarm(m, code), do: {stop(m, :alarm), ["ALARM:#{code}"]}

  ## Time

  @doc "Advance the model by `dt` milliseconds."
  def advance(%{state: :home} = m, dt) do
    left = m.homing_left - dt

    if left > 0,
      do: {%{m | homing_left: left}, []},
      else: {%{m | state: :idle, homing_left: 0, pos: {0.0, 0.0, 0.0}}, ["ok"]}
  end

  def advance(%{state: :jog} = m, dt), do: {move(m, dt), []}
  def advance(m, _dt), do: {m, []}

  defp move(m, dt) do
    case :queue.peek(m.queue) do
      :empty ->
        stop(m, :idle)

      {:value, {target, feed}} ->
        mm_per_ms = feed / 60_000
        dist = distance(m.pos, target)
        step = mm_per_ms * dt

        if step >= dist do
          m = %{m | pos: target, queue: :queue.drop(m.queue), feed: feed}
          move(m, dt - dist / mm_per_ms)
        else
          %{m | pos: toward(m.pos, target, step / dist), feed: feed}
        end
    end
  end

  ## Helpers

  defp status_line(m) do
    planner_free = max(@planner_blocks - :queue.len(m.queue), 0)

    Status.encode(%Status{
      state: m.state,
      mpos: m.pos,
      feed: m.feed,
      spindle: 0.0,
      buffer: {planner_free, 128}
    })
  end

  defp cancel_jog(%{state: :jog} = m), do: stop(m, :idle)
  defp cancel_jog(m), do: m

  defp reset(m) do
    {m, alarm} =
      case m.state do
        :jog -> {stop(m, :alarm), ["ALARM:3"]}
        :home -> {stop(m, :alarm), ["ALARM:6"]}
        _ -> {m, []}
      end

    locked = if m.state == :alarm, do: [@locked], else: []
    {m, alarm ++ [@banner] ++ locked}
  end

  defp stop(m, state), do: %{m | state: state, queue: :queue.new(), feed: 0.0, homing_left: 0}

  defp tail(m) do
    case :queue.peek_r(m.queue) do
      {:value, {target, _}} -> target
      :empty -> m.pos
    end
  end

  # Accepts exactly what CNC.Grbl.Command.jog/2 emits. Error codes follow Grbl:
  # 2 bad number, 20 unsupported, 22 feed not set.
  defp parse_jog(words) do
    words
    |> String.split(" ", trim: true)
    |> Enum.reduce_while(%{modes: [], delta: {0.0, 0.0, 0.0}, feed: nil}, &jog_word/2)
    |> case do
      {:error, _} = err -> err
      %{modes: modes} when modes != ["G21", "G91"] -> {:error, 20}
      %{feed: nil} -> {:error, 22}
      %{delta: delta, feed: feed} -> {:ok, delta, feed}
    end
  end

  defp jog_word(mode, acc) when mode in ["G91", "G21"],
    do: {:cont, %{acc | modes: Enum.sort([mode | acc.modes])}}

  defp jog_word(<<letter, value::binary>>, acc) when letter in ~c"XYZF" do
    case Float.parse(value) do
      {n, ""} when letter == ?F -> {:cont, %{acc | feed: n}}
      {n, ""} -> {:cont, %{acc | delta: put_axis(acc.delta, letter, n)}}
      _ -> {:halt, {:error, 2}}
    end
  end

  defp jog_word(_, _acc), do: {:halt, {:error, 20}}

  defp put_axis(delta, ?X, n), do: put_elem(delta, 0, n)
  defp put_axis(delta, ?Y, n), do: put_elem(delta, 1, n)
  defp put_axis(delta, ?Z, n), do: put_elem(delta, 2, n)

  defp within_travel({x, y, z}, {{x0, x1}, {y0, y1}, {z0, z1}}) do
    if x >= x0 and x <= x1 and y >= y0 and y <= y1 and z >= z0 and z <= z1,
      do: :ok,
      else: {:error, 15}
  end

  defp add({a, b, c}, {x, y, z}), do: {a + x, b + y, c + z}

  defp distance({a, b, c}, {x, y, z}),
    do: :math.sqrt((x - a) ** 2 + (y - b) ** 2 + (z - c) ** 2)

  defp toward({a, b, c}, {x, y, z}, f), do: {a + (x - a) * f, b + (y - b) * f, c + (z - c) * f}
end
