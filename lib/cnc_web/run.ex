defmodule CNCWeb.Run do
  @moduledoc """
  What the screens say about running a program, shared by the machine
  screen and the pendant: whether it fits the travel from the work zero
  (and what to do if not), how far a running job has got and how long is
  left (by time, not lines: `CNC.GCode.Timing`), and durations as a clock reads.
  """

  alias CNC.Machine.State
  alias CNC.Program

  @doc """
  How the program's moves sit in the travel from the current work zero:
  `[]` (fits), `[{axis, :low | :high, mm_outside}]`, or `:no_work_zero`.
  `lift` is a dry run's Z lift, which can take it past the top.
  """
  def fit(program, machine, lift \\ 0)
  def fit(%Program{gcode: %{bounds: nil}}, _machine, _lift), do: []
  def fit(_program, %State{wco: nil}, _lift), do: :no_work_zero

  def fit(%Program{gcode: %{bounds: bounds}}, %State{wco: wco, travel: travel}, lift) do
    for {axis, i} <- [x: 0, y: 1, z: 2],
        {pmin, pmax} = elem(bounds, i),
        {tmin, tmax} = elem(travel, i),
        offset = elem(wco, i) + if(axis == :z, do: lift, else: 0),
        {side, out} <- [low: tmin - (pmin + offset), high: pmax + offset - tmax],
        out > 0.0005,
        do: {axis, side, out}
  end

  @doc "One fit problem in words, and what to do about it."
  # Machine origin is front-left, Z at the top: say which edge, and what to do.
  def fit_issue({:z, :high, out}),
    do:
      "It lifts Z #{mm(out)} mm above the top of travel. Zero Z on the stock's surface " <>
        "(at least #{mm(out)} mm below the top)."

  def fit_issue({:z, :low, out}),
    do: "It cuts #{mm(out)} mm deeper than Z can reach. Raise the stock, or zero Z higher."

  def fit_issue({axis, side, out}) do
    edge =
      case {axis, side} do
        {:x, :low} -> "left"
        {:x, :high} -> "right"
        {:y, :low} -> "front"
        {:y, :high} -> "back"
      end

    "It goes #{mm(out)} mm past the #{edge} edge (#{axis |> to_string() |> String.upcase()}). " <>
      "Move the work zero #{mm(out)} mm #{opposite(edge)}."
  end

  # The controller acks a line when it's planned, well ahead of the tool:
  # its planner holds up to 15 moves (status: Bf, blocks free), and an arc
  # is many of them, some planned before the arc's line is acked. So which
  # line is being cut comes from where the tool is: the nearest of the
  # lines that can be running (those recently acked, and the one being
  # taken in) within @near mm, and how far along it. If the tool isn't on
  # any of them, from the planner: walking back from the newest line acked
  # past the blocks still waiting.
  @planner_blocks 15
  @near 0.5

  @doc """
  A running job's progress: `%{fraction, left, elapsed}`.

    * `fraction` (0.0..1.0) — the time the program has run, at 100%, over
      its whole time (`CNC.GCode.Timing`): a line of a long slow cut counts
      for more than one of a quick move. By lines when there's no timeline
      for it (another file, or a check run, where nothing moves).
    * `left` — seconds: what remains of the timeline at the current feed
      and rapid overrides, scaled by how the machine's actual pace compares
      with the estimate so far (between ½ and 2×), trusted more as more of
      it has run.
      nil for a check run.
    * `elapsed` — seconds the job has been running, not counting time
      paused (on hold, door open, waiting for Next line).
  """
  def progress(job, %State{} = machine, program) do
    elapsed = max(DateTime.diff(DateTime.utc_now(), job.started_at) - (job[:paused_s] || 0), 0)
    {feed_ov, rapid_ov, _} = machine.overrides || {100, 100, 100}

    case timed(job, program) do
      nil ->
        %{fraction: line_fraction(job, machine), left: nil, elapsed: round(elapsed)}

      program ->
        {lead, lead_done} = lead_in(program, job, machine)

        on_path =
          done(
            program,
            job,
            machine,
            &(Program.seconds(add(lead, &1), feed_ov, rapid_ov) - elapsed)
          )

        total = add(lead, Program.time_total(program))

        # Before the program's first move: how far through the lead-in
        done =
          if on_path == {0.0, 0.0, 0.0},
            do: scale(lead, lead_done),
            else: add(lead, on_path)

        total_100 = Program.seconds(total)
        fraction = if total_100 > 0, do: min(Program.seconds(done) / total_100, 1.0), else: 0.0

        total_now = Program.seconds(total, feed_ov, rapid_ov)
        done_now = Program.seconds(done, feed_ov, rapid_ov)
        left = max(total_now - done_now, 0.0)

        # The machine's own pace (how long the part done has actually
        # taken, against the estimate), trusted more the further it's got:
        # early on a fixed delay (the spindle spinning up, the first status)
        # would skew it
        pace =
          if done_now >= 5.0 and elapsed > 0,
            do: 1 + (min(max(elapsed / done_now, 0.5), 2.0) - 1) * fraction,
            else: 1.0

        %{fraction: fraction, left: round(left * pace), elapsed: round(elapsed)}
    end
  end

  # The program, if it's the job's file and has a timeline
  defp timed(%{mode: :check}, _program), do: nil

  defp timed(%{name: name}, %Program{name: name} = program),
    do: if(Program.time_total(program), do: program)

  defp timed(_job, _program), do: nil

  # Time done, through the line being cut. off_by: how far a time done is
  # from the time the job has actually been running.
  defp done(program, job, machine, off_by) do
    recent = job[:recent] || []
    {floor, from_blocks} = walk(program, recent, waiting(machine))

    case locate(program, job, machine, floor, off_by) do
      nil -> from_blocks
      done -> done
    end
  end

  # From the planner: walking back from the newest line acked past the
  # blocks still waiting. {the line that gives, the time done}. A lower
  # bound: an arc being taken in has blocks waiting that aren't its acked
  # lines'.
  defp walk(_program, [], _waiting), do: {0, {0.0, 0.0, 0.0}}
  defp walk(program, recent, waiting), do: walk(program, recent, waiting, nil)

  # More waiting than lines remembered: up to the oldest
  defp walk(program, [], _waiting, oldest), do: {oldest, Program.time_at(program, oldest - 1)}

  defp walk(program, [line | older], waiting, _) do
    blocks = Program.time_blocks(program, line)

    cond do
      waiting <= 0 ->
        {line, Program.time_at(program, line)}

      # Being cut: (blocks - waiting) of its blocks done
      blocks >= waiting ->
        {line,
         lerp(
           Program.time_at(program, line - 1),
           Program.time_at(program, line),
           (blocks - waiting) / blocks
         )}

      true ->
        walk(program, older, waiting - blocks, line)
    end
  end

  # From where the tool is: of the lines that can be running (from the
  # planner's lower bound up to the one being taken in), those whose moves
  # it's on (within @near mm), and how far along. Where more than one is
  # (a point two passes share), the one whose time done is nearest the
  # time the job has been running: they're usually a whole pass apart.
  defp locate(program, job, %State{wpos: {x, y, z}}, floor, off_by) do
    # A dry run cuts the same path, Z lifted
    lift = lift(job)

    [job[:feeding] | job[:recent] || []]
    |> Enum.reject(&(is_nil(&1) or &1 < floor))
    |> Enum.uniq()
    |> Enum.flat_map(fn line ->
      case Program.locate(program, line, {x, y, z - lift}) do
        {d, along} when d <= @near ->
          [lerp(Program.time_at(program, line - 1), Program.time_at(program, line), along)]

        _ ->
          []
      end
    end)
    |> Enum.min_by(&abs(off_by.(&1)), fn -> nil end)
  end

  defp locate(_program, _job, _machine, _floor, _off_by), do: nil

  # The lead-in: from where the tool was at Start to the program's first
  # move (the file's opening moves, which can't be timed until it starts).
  # {its time, how far through it the tool is}.
  defp lead_in(program, %{start: {_, _, _} = start} = job, %State{wpos: {_, _, _} = now} = m) do
    lift = lift(job)

    case Program.lead_in(program, start,
           max_rate: m.max_rate,
           accel: m.accel,
           junction: m.junction
         ) do
      {lead, {x, y, z}} ->
        to = {x, y, z + lift}
        whole = distance(start, to)
        {lead, if(whole > 0, do: min(max(1 - distance(now, to) / whole, 0.0), 1.0), else: 1.0)}

      nil ->
        {{0.0, 0.0, 0.0}, 1.0}
    end
  end

  defp lead_in(_program, _job, _machine), do: {{0.0, 0.0, 0.0}, 1.0}

  defp lift(%{mode: {:dry, mm}}), do: mm
  defp lift(_job), do: 0

  defp distance({ax, ay, az}, {bx, by, bz}),
    do: :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by) + (az - bz) * (az - bz))

  defp add({f0, r0, x0}, {f1, r1, x1}), do: {f0 + f1, r0 + r1, x0 + x1}
  defp scale({f, r, x}, t), do: {f * t, r * t, x * t}

  defp lerp({f0, r0, x0}, {f1, r1, x1}, t),
    do: {f0 + (f1 - f0) * t, r0 + (r1 - r0) * t, x0 + (x1 - x0) * t}

  defp waiting(%State{buffer: {free, _}}) when is_integer(free),
    do: max(@planner_blocks - free, 0)

  defp waiting(_), do: 0

  defp line_fraction(%{total: total}, _machine) when total == 0, do: 0.0
  defp line_fraction(job, machine), do: min(max(job.acked - waiting(machine), 0) / job.total, 1.0)

  @doc """
  A stock issue (`CNCApp.Stock.issues/3`) in words. With a bit, an edge
  issue is where the cutter reaches (the clamps' concern); without, the path.
  """
  def stock_issue(issue, stock, bit \\ nil)

  def stock_issue({:edge, edge, out}, _stock, nil),
    do: "Cuts #{mm(out)} mm past the stock's #{edge} edge."

  def stock_issue({:edge, edge, out}, _stock, _bit),
    do: "The bit reaches #{mm(out)} mm past the stock's #{edge} edge: keep clamps clear."

  def stock_issue({:through, out}, stock, _bit),
    do:
      "Cuts #{mm(out)} mm deeper than the stock is thick (#{mm(stock.thickness)} mm): " <>
        "into what's under it."

  @doc "The stock in a few words: `300 × 200 × 18 mm, zero front-left`."
  def stock_label(%{width: w, depth: d, thickness: t, zero: zero}),
    do:
      "#{mm(w)} × #{mm(d)} × #{mm(t)} mm, zero #{if zero == :center, do: "centred", else: "front-left"}"

  @doc "The bit in a few words: `6.35 mm flat end mill`, `90° V-bit, 12 mm`."
  def bit_label(%{diameter: d, kind: :flat}), do: "#{size(d)} mm flat end mill"
  def bit_label(%{diameter: d, kind: :ball}), do: "#{size(d)} mm ball nose"
  def bit_label(%{diameter: d, kind: :v, angle: a}), do: "#{a}° V-bit, #{size(d)} mm"

  @doc "A size to two decimals, trailing zeros dropped: 6.35, 3.18, 12."
  def size(v),
    do:
      v
      |> Float.round(2)
      |> :erlang.float_to_binary(decimals: 2)
      |> String.replace(~r/\.?0+$/, "")

  @doc "A kind of bit, as its button says."
  def kind_label(:flat), do: "Flat end mill"
  def kind_label(:ball), do: "Ball nose"
  def kind_label(:v), do: "V-bit"

  @doc "Where the work zero is on the stock, in words."
  def zero_label(:front_left), do: "on top, front-left corner"
  def zero_label(:center), do: "on top, centre"

  @doc "Seconds as a clock reads: 4:05, 1:02:03."
  def duration(seconds) when is_integer(seconds) and seconds >= 3600,
    do: "#{div(seconds, 3600)}:#{pad(div(rem(seconds, 3600), 60))}:#{pad(rem(seconds, 60))}"

  def duration(seconds) when is_integer(seconds),
    do: "#{div(max(seconds, 0), 60)}:#{pad(rem(max(seconds, 0), 60))}"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp mm(v),
    do: v |> Float.round(1) |> :erlang.float_to_binary(decimals: 1) |> String.trim_trailing(".0")

  defp opposite("left"), do: "right"
  defp opposite("right"), do: "left"
  defp opposite("front"), do: "back"
  defp opposite("back"), do: "front"
end
