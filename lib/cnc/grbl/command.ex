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
