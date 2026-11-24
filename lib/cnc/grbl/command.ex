defmodule CNC.Grbl.Command do
  @moduledoc """
  Line commands. Returned without the trailing newline.
  """

  @axes ~w(X Y Z)

  @doc "Clear an alarm lock (`$X`)."
  def unlock, do: "$X"

  @doc "Run the homing cycle (`$H`)."
  def home, do: "$H"

  @doc "Print all settings (`$$`): one `$N=value` line each, then `ok`."
  def settings, do: "$$"

  @doc "Print build info (`$I`): `[VER:...]`, `[OPT:...]`, and on grblHAL `[FIRMWARE:...]`, `[DRIVER:...]`."
  def build_info, do: "$I"

  @doc """
  Set the G54 work offset so the current position reads as the given work
  coordinates (usually zero): `G10 L20 P1 X.. Y.. Z..`.

      iex> CNC.Grbl.Command.set_work(x: 0, y: 0)
      "G10 L20 P1 X0.000 Y0.000"
  """
  def set_work(axes) when axes != [] do
    words =
      for axis <- [:x, :y, :z],
          Keyword.has_key?(axes, axis),
          do: String.upcase(to_string(axis)) <> fmt(Keyword.fetch!(axes, axis), 3)

    "G10 L20 P1 " <> Enum.join(words, " ")
  end

  @doc """
  Set the G54 work zero at absolute machine coordinates:
  `G10 L2 P1 X.. Y.. Z..`. Independent of where the tool is.

      iex> CNC.Grbl.Command.set_work_offset(x: 300, z: -42.5)
      "G10 L2 P1 X300.000 Z-42.500"
  """
  def set_work_offset(axes) when axes != [] do
    words =
      for axis <- [:x, :y, :z],
          Keyword.has_key?(axes, axis),
          do: String.upcase(to_string(axis)) <> fmt(Keyword.fetch!(axes, axis), 3)

    "G10 L2 P1 " <> Enum.join(words, " ")
  end

  @doc """
  Relative, metric jog: `$J=G91 G21 X.. Y.. Z.. F..`.

  Axes that round to zero at 3 decimals are omitted. At least one axis must
  be non-zero, and the feed (mm/min) must be positive.

      iex> CNC.Grbl.Command.jog({1.5, 0, -0.25}, 1200)
      "$J=G91 G21 X1.500 Z-0.250 F1200"
  """
  def jog({_, _, _} = delta, feed) when is_number(feed) and feed > 0 do
    words =
      delta
      |> Tuple.to_list()
      |> Enum.zip(@axes)
      |> Enum.map(fn {d, axis} -> {axis, fmt(d, 3)} end)
      |> Enum.reject(fn {_, s} -> zero?(s) end)

    if words == [], do: raise(ArgumentError, "jog needs a non-zero axis: #{inspect(delta)}")

    axes = Enum.map_join(words, " ", fn {axis, s} -> axis <> s end)
    "$J=G91 G21 #{axes} F#{fmt(feed, 0)}"
  end

  defp fmt(n, decimals), do: :erlang.float_to_binary(n / 1, decimals: decimals)

  # Numeric compare, so "-0.000" counts as zero too.
  defp zero?(s), do: String.to_float(s) == 0.0
end
