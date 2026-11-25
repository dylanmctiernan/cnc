defmodule CNC.GCode.Timing do
  @moduledoc """
  How long a program takes, line by line, the way the controller's planner
  moves the machine (Grbl's, which FluidNC keeps):

    * each move's top speed is its feed (`F`), or for a rapid the axes'
      max rates, and never more than any axis it uses allows (a Z move
      at Z's rate, a diagonal at whichever axis runs out first)
    * acceleration likewise, from the axes' accelerations
    * at each corner the speed is limited by the junction deviation: a
      straight continuation keeps full speed, a reversal stops, a 90°
      corner slows to `sqrt(a·δ·s/(1-s))` with `s = sin(θ/2)`
    * a backward pass makes sure every move can slow down in time for the
      next; a forward pass that it can get up to speed from the last;
      each move is then a trapezoid (or triangle) of speed over distance
    * it starts and ends at rest, and stops for a dwell

  Each line's time is kept in three parts, so overrides can be applied
  later: `feed` (cutting at cruise speed: the feed override scales it),
  `rapid` (rapids at cruise speed: the rapid override scales it) and
  `fixed` (speeding up and slowing down, and dwells: neither changes them
  much). An approximation: at 200% feed, a move too short to reach its
  speed takes no less time, which is what the machine does too.

  The result is a timeline: for each line with a move, the cumulative
  `{feed, rapid, fixed}` seconds up to and including it, and how many
  planner blocks the controller makes of it (an arc is many: with the
  planner's free blocks, that says how far through the queued lines the
  tool is). Packed into a binary (shared, not copied, between processes)
  and searched by line.
  """

  @typedoc """
  A move: `{line, :feed | :rapid, length_mm, unit_vector, feed_mm_min, blocks}`
  (blocks: the controller's planner moves it counts for), or a dwell.
  """
  @type move ::
          {pos_integer, :feed | :rapid, float, {float, float, float}, number | nil,
           non_neg_integer}
          | {pos_integer, :dwell, float}

  @entry 32

  @doc """
  Plan the moves (in order). Options: `:max_rate` `{x, y, z}` mm/min,
  `:accel` `{x, y, z}` mm/s², `:junction` mm. Returns the timeline.
  """
  @spec plan([move], keyword) :: binary
  def plan(moves, opts \\ []) do
    rates = opts |> Keyword.get(:max_rate, {3000.0, 3000.0, 1200.0}) |> per_second()
    accel = Keyword.get(opts, :accel, {500.0, 500.0, 200.0})
    junction = Keyword.get(opts, :junction, 0.01)

    moves
    |> limits(rates, accel, junction)
    |> backward()
    |> forward()
    |> timeline()
  end

  @doc "Cumulative `{feed, rapid, fixed}` seconds through `line` (zeros before the first)."
  def at(timeline, line) when is_binary(timeline) do
    case find(timeline, line, 0, div(byte_size(timeline), @entry) - 1, nil) do
      nil -> {0.0, 0.0, 0.0}
      i -> entry(timeline, i)
    end
  end

  @doc "The controller's planner blocks for `line` (0 if it doesn't move)."
  def blocks(timeline, line) when is_binary(timeline) do
    case find(timeline, line, 0, div(byte_size(timeline), @entry) - 1, nil) do
      nil ->
        0

      i ->
        <<n::32, b::32, _::binary>> = binary_part(timeline, i * @entry, @entry)
        if n == line, do: b, else: 0
    end
  end

  @doc "The whole program's `{feed, rapid, fixed}` seconds."
  def total(<<>>), do: {0.0, 0.0, 0.0}
  def total(timeline), do: entry(timeline, div(byte_size(timeline), @entry) - 1)

  @doc "Seconds at the feed and rapid overrides (percent)."
  def seconds({feed, rapid, fixed}, feed_ov \\ 100, rapid_ov \\ 100),
    do: feed * 100 / max(feed_ov, 1) + rapid * 100 / max(rapid_ov, 1) + fixed

  ## Planning

  # Each move's cruise speed, acceleration and the most it can enter at
  # (the corner from the move before). Dwells become stops.
  defp limits(moves, rates, accel, delta) do
    {planned, _prev} =
      Enum.map_reduce(moves, nil, fn
        {n, :dwell, s}, _prev ->
          {{n, :dwell, s}, nil}

        {n, kind, len, u, feed, blocks}, prev ->
          top = axis_limit(rates, u)
          v = if kind == :rapid or feed in [nil, 0, 0.0], do: top, else: min(feed / 60, top)
          a = axis_limit(accel, u)
          entry_max = corner(prev, u, v, a, delta)
          {{n, kind, len, v, a, entry_max, blocks}, {u, v, a}}
      end)

    planned
  end

  # The most each axis allows along u: min over the axes it uses of limit/|u|.
  defp axis_limit({lx, ly, lz}, {ux, uy, uz}) do
    [{lx, ux}, {ly, uy}, {lz, uz}]
    |> Enum.filter(fn {_, c} -> abs(c) > 1.0e-9 end)
    |> Enum.map(fn {l, c} -> l / abs(c) end)
    |> Enum.min(fn -> 0.0 end)
  end

  defp corner(nil, _u, _v, _a, _delta), do: 0.0

  defp corner({{px, py, pz}, pv, pa}, {ux, uy, uz}, v, a, delta) do
    cos = -(px * ux + py * uy + pz * uz)
    cap = min(pv, v)

    cond do
      # Straight on
      cos < -0.999999 ->
        cap

      # Reversal
      cos > 0.999999 ->
        0.0

      true ->
        sin_half = :math.sqrt(0.5 * (1 - cos))
        min(cap, :math.sqrt(min(a, pa) * delta * sin_half / (1 - sin_half)))
    end
  end

  # Backward: each move's entry no faster than it can slow from in time for
  # the next (the last ends at rest). Returns them in order with
  # {entry, exit} bounds.
  defp backward(planned) do
    {out, _} =
      planned
      |> Enum.reverse()
      |> Enum.reduce({[], 0.0}, fn
        {_, :dwell, _} = dwell, {acc, _next} ->
          {[dwell | acc], 0.0}

        {n, kind, len, v, a, entry_max, blocks}, {acc, next} ->
          entry = min(entry_max, :math.sqrt(next * next + 2 * a * len))
          {[{n, kind, len, v, a, entry, next, blocks} | acc], entry}
      end)

    out
  end

  # Forward: no faster than it can speed up to from the move before (the
  # first starts at rest). Then each move's time.
  defp forward(planned) do
    {out, _} =
      Enum.map_reduce(planned, 0.0, fn
        {n, :dwell, s}, _prev ->
          {{n, 0.0, 0.0, s, 0}, 0.0}

        {n, kind, len, v, a, entry_bwd, exit_bwd, blocks}, prev ->
          entry = min(entry_bwd, prev)
          exit = min(exit_bwd, :math.sqrt(entry * entry + 2 * a * len))
          {cruise, ramps} = trapezoid(len, entry, exit, v, a)

          case kind do
            :feed -> {{n, cruise, 0.0, ramps, blocks}, exit}
            :rapid -> {{n, 0.0, cruise, ramps, blocks}, exit}
          end
      end)

    out
  end

  # Seconds at cruise speed and seconds speeding up/slowing down, for a move
  # of `len` mm entered at `ve`, left at `vx`, cruising at `vc`, accel `a`.
  defp trapezoid(len, _ve, _vx, vc, a) when len <= 0 or vc <= 0 or a <= 0, do: {0.0, 0.0}

  defp trapezoid(len, ve, vx, vc, a) do
    up = (vc * vc - ve * ve) / (2 * a)
    down = (vc * vc - vx * vx) / (2 * a)

    if up + down <= len do
      {(len - up - down) / vc, (vc - ve) / a + (vc - vx) / a}
    else
      # Never reaches cruise: up to a peak and straight back down
      peak = :math.sqrt(max((2 * a * len + ve * ve + vx * vx) / 2, 0.0))
      {0.0, max(peak - ve, 0.0) / a + max(peak - vx, 0.0) / a}
    end
  end

  ## The timeline

  # Lines arrive in order (several moves per line for an arc): sum each
  # line's, then pack the running totals.
  defp timeline(times) do
    {acc, line, b, f, r, x} =
      Enum.reduce(times, {[], nil, 0, 0.0, 0.0, 0.0}, fn {n, df, dr, dx, db},
                                                         {acc, line, b, f, r, x} ->
        if line != nil and n != line,
          do: {[pack(line, b, f, r, x) | acc], n, db, f + df, r + dr, x + dx},
          else: {acc, n, b + db, f + df, r + dr, x + dx}
      end)

    acc = if line, do: [pack(line, b, f, r, x) | acc], else: acc
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp pack(n, b, f, r, x), do: <<n::32, b::32, f::float-64, r::float-64, x::float-64>>

  defp entry(bin, i) do
    <<_::32, _::32, f::float-64, r::float-64, x::float-64>> =
      binary_part(bin, i * @entry, @entry)

    {f, r, x}
  end

  defp line_at(bin, i) do
    <<n::32>> = binary_part(bin, i * @entry, 4)
    n
  end

  # The last entry whose line is <= line
  defp find(_bin, _line, lo, hi, best) when lo > hi, do: best

  defp find(bin, line, lo, hi, best) do
    mid = div(lo + hi, 2)

    if line_at(bin, mid) <= line,
      do: find(bin, line, mid + 1, hi, mid),
      else: find(bin, line, lo, mid - 1, best)
  end

  defp per_second({x, y, z}), do: {x / 60, y / 60, z / 60}
end
