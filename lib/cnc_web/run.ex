defmodule CNCWeb.Run do
  @moduledoc """
  What the screens say about running a program, shared by the machine
  screen and the pendant: whether it fits the travel from the work zero
  (and what to do if not), how far a running job has got, how long is
  left, and durations as a clock reads.
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

  # How much has actually run: the controller accepts lines into its
  # planner well ahead of the tool, so the lines acked minus the moves still
  # waiting there (its status: Bf, planner blocks free) estimate what's
  # been done. On a short file the planner can hold most of it.
  @planner_blocks 15

  @doc "How much of a running job has run, 0.0..1.0."
  def fraction(%{total: total}, _machine) when total == 0, do: 0.0

  def fraction(job, %State{buffer: buffer}) do
    waiting =
      case buffer do
        {free, _} when is_integer(free) -> max(@planner_blocks - free, 0)
        _ -> 0
      end

    min(max(job.acked - waiting, 0) / job.total, 1.0)
  end

  @doc """
  Seconds left: early on, from the file's estimate (at the feed override);
  once a few percent are done, from the pace so far. nil if unknown.
  """
  def time_left(fraction, _elapsed, %Program{gcode: %{seconds: secs}}, ov) when fraction < 0.05,
    do: round(secs * (1 - fraction) * 100 / max(ov, 10))

  def time_left(fraction, elapsed, _program, _ov) when fraction > 0 and fraction < 1,
    do: round(elapsed / fraction - elapsed)

  def time_left(_, _, _, _), do: nil

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
