defmodule CNC.GCode do
  @moduledoc """
  G-code → toolpath, for previewing a file before it's run. Pure: no
  processes, no IO.

  Interprets the subset CAM programs for a 3-axis router emit (Grbl /
  FluidNC dialect): `G0` `G1` `G2` `G3` with `I J K` or `R`, `G17`–`G19`,
  `G20`/`G21`, `G90`/`G91`, `G90.1`/`G91.1`, `G4`, `F`, `S`, `T`, `M3`–`M6`,
  `M2`/`M30`, comments `( )` and `;`, line numbers and `%`.

  Positions are in the program's own (work) coordinates, in mm. Moves before
  X and Y are both known (the program's start depends on where the machine
  is) update the position but aren't drawn. Anything that can't be previewed
  faithfully (machine-coordinate moves, other work offsets, probing, canned
  cycles, unknown codes) becomes a warning with its first line number; the
  rest of the file still parses.

  Arcs are drawn as chords at most `@chord_tolerance` mm off the true arc.
  """
  use Boundary, deps: [], exports: [Program]

  alias CNC.GCode.Program

  # Preview resolution: the 1250 mm bed is ~1.5 mm a pixel on most screens.
  @chord_tolerance 0.1
  @max_arc_chords 128

  @doc """
  Parse a G-code file. Options:

    * `:rapid_rate` — mm/min used for G0 in the time estimate (default 3000)
  """
  @spec parse(binary, keyword) :: Program.t()
  def parse(text, opts \\ []) when is_binary(text) do
    rapid_rate = Keyword.get(opts, :rapid_rate, 3000.0)

    {state, _} =
      text
      |> String.split(["\r\n", "\n", "\r"])
      |> Enum.reduce({initial(), 1}, fn line, {st, n} -> {interpret(st, line, n), n + 1} end)

    finish(state, rapid_rate)
  end

  ## Interpreter state

  defp initial do
    %{
      pos: {0.0, 0.0, 0.0},
      # X and Y given at least once: before that, moves aren't drawn
      x_known?: false,
      y_known?: false,
      motion: nil,
      units: 1.0,
      absolute?: true,
      arc_absolute?: false,
      plane: :xy,
      feed: nil,
      # Packed segments (see Program), reversed iodata; bounds as we go.
      path: [],
      count: 0,
      all: nil,
      cut: nil,
      rapid_mm: 0.0,
      cut_mm: 0.0,
      cut_minutes: 0.0,
      dwell_s: 0.0,
      tools: [],
      tool: nil,
      max_spindle: 0.0,
      inches?: false,
      no_feed?: false,
      warnings: %{},
      lines: 0,
      ended?: false
    }
  end

  defp interpret(%{ended?: true} = st, _line, _n), do: st

  defp interpret(st, line, n) do
    case words(line) do
      [] -> st
      :error -> warn(st, :bad_line, n)
      words -> %{execute(st, words, n) | lines: st.lines + 1}
    end
  end

  # "G1 X10 (comment) Y2.5 ; more" -> [{"G", 1.0}, {"X", 10.0}, {"Y", 2.5}].
  # One pass over the bytes: spaces anywhere, ( ) comments, ; to end of line,
  # % and a trailing *checksum are skipped. Anything else is an error.
  defp words(line), do: tokens(line, [])

  defp tokens(<<>>, acc), do: Enum.reverse(acc)
  defp tokens(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?%], do: tokens(rest, acc)
  defp tokens(<<?;, _::binary>>, acc), do: tokens(<<>>, acc)
  defp tokens(<<?*, _::binary>>, acc), do: tokens(<<>>, acc)

  defp tokens(<<?(, rest::binary>>, acc) do
    case :binary.split(rest, ")") do
      [_, after_comment] -> tokens(after_comment, acc)
      [_] -> :error
    end
  end

  defp tokens(<<c, rest::binary>>, acc) when c in ?a..?z,
    do: tokens(<<c - 32, rest::binary>>, acc)

  defp tokens(<<c, rest::binary>>, acc) when c in ?A..?Z do
    {num, rest} = number(skip_spaces(rest), [])

    case to_float(num) do
      {:ok, f} -> tokens(rest, [{<<c>>, f} | acc])
      :error -> :error
    end
  end

  defp tokens(_, _), do: :error

  defp skip_spaces(<<c, rest::binary>>) when c in [?\s, ?\t], do: skip_spaces(rest)
  defp skip_spaces(rest), do: rest

  defp number(<<c, rest::binary>>, acc) when c in ?0..?9 or c in [?., ?-, ?+],
    do: number(rest, [c | acc])

  defp number(<<c, rest::binary>>, acc) when c in [?\s, ?\t], do: number(rest, acc)
  defp number(rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  # "5.", ".5", "-.5", "+2" are all valid G-code numbers.
  defp to_float(""), do: :error

  defp to_float(v) do
    {sign, digits} =
      case v do
        "-" <> d -> {"-", d}
        "+" <> d -> {"", d}
        d -> {"", d}
      end

    digits = if String.starts_with?(digits, "."), do: "0" <> digits, else: digits
    digits = if String.ends_with?(digits, "."), do: digits <> "0", else: digits

    case Float.parse(sign <> digits) do
      {f, ""} -> {:ok, f}
      _ -> :error
    end
  end

  defp execute(st, words, n) do
    gs = for {"G", v} <- words, do: v
    ms = for {"M", v} <- words, do: v
    values = Map.new(words)
    get = &Map.get(values, &1)

    st = Enum.reduce(gs, st, &modal_g(&2, &1, n))
    st = if f = get.("F"), do: %{st | feed: f * st.units}, else: st
    st = if s = get.("S"), do: %{st | max_spindle: max(st.max_spindle, s)}, else: st
    st = if t = get.("T"), do: %{st | tool: trunc(t)}, else: st
    st = Enum.reduce(ms, st, &m_code(&2, &1, n))
    st = if Enum.any?(gs, &(&1 == 4.0)), do: dwell(st, get.("P")), else: st

    unknown = for l <- Map.keys(values), l not in ~w(G M X Y Z I J K R F S T P N), do: l
    st = Enum.reduce(unknown, st, &warn(&2, {:unknown_word, &1}, n))

    axes = for l <- ~w(X Y Z), v = get.(l), into: %{}, do: {l, v}
    non_motion_g? = Enum.any?(gs, &(&1 in [4.0, 10.0, 28.0, 30.0, 53.0, 92.0]))

    cond do
      axes == %{} -> st
      non_motion_g? -> st
      st.motion == nil -> warn(st, :no_motion_mode, n)
      true -> move(st, axes, get, n)
    end
  end

  @plain_gs [17.0, 18.0, 19.0, 20.0, 21.0, 40.0, 49.0, 54.0, 80.0, 90.0, 91.0, 94.0]

  defp modal_g(st, g, n) do
    case g do
      g when g in [0.0, 1.0, 2.0, 3.0] -> %{st | motion: trunc(g)}
      17.0 -> %{st | plane: :xy}
      18.0 -> %{st | plane: :xz}
      19.0 -> %{st | plane: :yz}
      20.0 -> %{st | units: 25.4, inches?: true}
      21.0 -> %{st | units: 1.0}
      90.0 -> %{st | absolute?: true}
      91.0 -> %{st | absolute?: false}
      90.1 -> %{st | arc_absolute?: true}
      91.1 -> %{st | arc_absolute?: false}
      80.0 -> %{st | motion: nil}
      4.0 -> st
      g when g in @plain_gs -> st
      g when g in [28.0, 30.0] -> warn(st, :predefined_position, n)
      53.0 -> warn(st, :machine_coordinates, n)
      g when g in [55.0, 56.0, 57.0, 58.0, 59.0] -> warn(st, :other_work_offset, n)
      92.0 -> warn(st, :coordinate_offset, n)
      10.0 -> warn(st, :coordinate_offset, n)
      g when g >= 38.0 and g < 39.0 -> warn(st, :probing, n)
      g when g >= 81.0 and g <= 89.0 -> warn(%{st | motion: nil}, :canned_cycle, n)
      g -> warn(st, {:unsupported_g, g}, n)
    end
  end

  defp m_code(st, m, n) do
    case m do
      6.0 -> %{st | tools: st.tools ++ [st.tool]}
      m when m in [2.0, 30.0] -> %{st | ended?: true}
      m when m in [0.0, 1.0, 3.0, 4.0, 5.0, 7.0, 8.0, 9.0] -> st
      m -> warn(st, {:unsupported_m, m}, n)
    end
  end

  defp dwell(st, nil), do: st
  defp dwell(st, p), do: %{st | dwell_s: st.dwell_s + p}

  ## Motion

  defp move(st, axes, get, n) do
    {x0, y0, z0} = from = st.pos

    to =
      {target(st, axes["X"], x0), target(st, axes["Y"], y0), target(st, axes["Z"], z0)}

    drawn? = st.x_known? and st.y_known?

    st = %{
      st
      | pos: to,
        x_known?: st.x_known? or Map.has_key?(axes, "X"),
        y_known?: st.y_known? or Map.has_key?(axes, "Y")
    }

    cond do
      not drawn? ->
        st

      st.motion == 0 ->
        add(st, :rapid, [from, to], n)

      st.motion == 1 ->
        add(st, :feed, [from, to], n)

      st.plane != :xy ->
        # Arcs in XZ/YZ: drawn straight, flagged.
        st |> warn(:arc_plane, n) |> add(:feed, [from, to], n)

      true ->
        case arc_points(st, from, to, get) do
          {:ok, points} -> add(st, :feed, points, n)
          :error -> st |> warn(:bad_arc, n) |> add(:feed, [from, to], n)
        end
    end
  end

  defp target(_st, nil, current), do: current
  defp target(%{absolute?: true, units: u}, v, _current), do: v * u
  defp target(%{absolute?: false, units: u}, v, current), do: current + v * u

  defp add(st, kind, [first | rest], n) do
    code = if kind == :rapid, do: 0.0, else: 1.0
    cut? = kind == :feed

    acc0 =
      {first, st.path, 0.0, 0, grow(first, st.all),
       if(cut?, do: grow(first, st.cut), else: st.cut)}

    # One pass: pack each segment, sum its length, grow the bounds.
    {_, path, len, count, all, cut} =
      Enum.reduce(rest, acc0, fn {x1, y1, z1} = b,
                                 {{x0, y0, z0} = a, path, len, count, all, cut} ->
        packed =
          <<code::float-32-little, x0::float-32-little, y0::float-32-little, z0::float-32-little,
            x1::float-32-little, y1::float-32-little, z1::float-32-little, n::float-32-little>>

        {b, [path | packed], len + dist(a, b), count + 1, grow(b, all),
         if(cut?, do: grow(b, cut), else: cut)}
      end)

    st = %{st | path: path, count: st.count + count, all: all, cut: cut}

    case kind do
      :rapid ->
        %{st | rapid_mm: st.rapid_mm + len}

      :feed when st.feed in [nil, 0.0] ->
        st = if len > 0, do: %{st | no_feed?: true}, else: st
        %{st | cut_mm: st.cut_mm + len}

      :feed ->
        %{st | cut_mm: st.cut_mm + len, cut_minutes: st.cut_minutes + len / st.feed}
    end
  end

  # Points along a G2/G3 arc in the XY plane, from `from` to `to`, Z moving
  # linearly (helix). Centre from I/J (offsets, or absolute with G90.1) or R.
  defp arc_points(st, {x0, y0, z0} = from, {x1, y1, z1} = to, get) do
    cw? = st.motion == 2

    center =
      case {get.("R"), get.("I"), get.("J")} do
        {r, _, _} when is_number(r) -> r_center(from, to, r * st.units, cw?)
        {nil, nil, nil} -> :error
        {nil, i, j} -> {:ok, ij_center(st, from, i || 0.0, j || 0.0)}
      end

    with {:ok, {cx, cy}} <- center do
      r = :math.sqrt((x0 - cx) * (x0 - cx) + (y0 - cy) * (y0 - cy))
      a0 = :math.atan2(y0 - cy, x0 - cx)
      a1 = :math.atan2(y1 - cy, x1 - cx)

      sweep =
        cond do
          cw? -> a1 - a0 - if(a1 >= a0, do: 2 * :math.pi(), else: 0.0)
          true -> a1 - a0 + if(a1 <= a0, do: 2 * :math.pi(), else: 0.0)
        end

      # Start and end at the same point: a full circle (sweep is ±2π).
      step =
        if r > @chord_tolerance,
          do: 2 * :math.acos(1 - @chord_tolerance / r),
          else: :math.pi() / 2

      count = min(max(ceil(abs(sweep) / step), 1), @max_arc_chords)

      points =
        for k <- 1..count do
          t = k / count
          a = a0 + sweep * t

          if k == count,
            do: to,
            else: {cx + r * :math.cos(a), cy + r * :math.sin(a), z0 + (z1 - z0) * t}
        end

      {:ok, [from | points]}
    end
  end

  defp ij_center(%{arc_absolute?: true, units: u}, _from, i, j), do: {i * u, j * u}
  defp ij_center(%{units: u}, {x0, y0, _}, i, j), do: {x0 + i * u, y0 + j * u}

  # Grbl's radius-format centre: R < 0 picks the long way round.
  defp r_center({x0, y0, _}, {x1, y1, _}, r, cw?) do
    {dx, dy} = {x1 - x0, y1 - y0}
    d2 = dx * dx + dy * dy
    disc = 4 * r * r - d2

    if d2 == 0 or disc < -1.0e-9 do
      :error
    else
      h = -:math.sqrt(max(disc, 0.0)) / :math.sqrt(d2)
      h = if cw?, do: h, else: -h
      h = if r < 0, do: -h, else: h
      {:ok, {x0 + 0.5 * (dx - dy * h), y0 + 0.5 * (dy + dx * h)}}
    end
  end

  defp dist({ax, ay, az}, {bx, by, bz}) do
    {dx, dy, dz} = {bx - ax, by - ay, bz - az}
    :math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  ## Warnings

  defp warn(st, kind, n) do
    update_in(st.warnings, fn ws ->
      Map.update(ws, kind, {n, 1}, fn {first, count} -> {first, count + 1} end)
    end)
  end

  ## Result

  defp finish(st, rapid_rate) do
    st = if st.inches?, do: warn(st, :inches, 0), else: st
    st = if st.no_feed?, do: warn(st, :no_feed, 0), else: st

    %Program{
      path: IO.iodata_to_binary(st.path),
      segment_count: st.count,
      lines: st.lines,
      cut_bounds: st.cut,
      bounds: st.all,
      cut_mm: st.cut_mm,
      rapid_mm: st.rapid_mm,
      seconds: st.cut_minutes * 60 + st.rapid_mm / rapid_rate * 60 + st.dwell_s,
      tools: Enum.uniq(st.tools),
      max_spindle: st.max_spindle,
      warnings:
        st.warnings
        |> Enum.map(fn {kind, {first, count}} -> %{kind: kind, line: first, count: count} end)
        |> Enum.sort_by(& &1.line)
    }
  end

  defp grow({x, y, z}, nil), do: {{x, x}, {y, y}, {z, z}}

  defp grow({x, y, z}, {{x0, x1}, {y0, y1}, {z0, z1}}),
    do: {{min(x0, x), max(x1, x)}, {min(y0, y), max(y1, y)}, {min(z0, z), max(z1, z)}}

  @doc """
  The segments of a parsed program as tuples:
  `[{:rapid | :feed, {x, y, z}, {x, y, z}, line}]`. Coordinates come back at
  float32 precision (about 0.1 µm at 1 m).
  """
  def segments(%Program{path: path}) do
    for <<code::float-32-little, x0::float-32-little, y0::float-32-little, z0::float-32-little,
          x1::float-32-little, y1::float-32-little, z1::float-32-little,
          n::float-32-little <- path>> do
      {if(code == 0.0, do: :rapid, else: :feed), {x0, y0, z0}, {x1, y1, z1}, trunc(n)}
    end
  end
end
