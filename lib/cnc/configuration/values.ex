defmodule CNC.Configuration.Values do
  @moduledoc """
  Config values: read out of a config's text as `{path, value}` (paths as
  FluidNC takes them, `axes/x/max_rate_mm_per_min`), compared (numbers as
  numbers) and diffed.
  """

  alias CNC.Configuration.Yaml

  @doc ~S"""
  The values in a config's text, in order: `[{path, value}]`, with paths
  as FluidNC takes them (lower case).

      iex> CNC.Configuration.Values.parse(~s|name: "R"\naxes:\n  X:\n    steps_per_mm: 80\n    motor0:\n      pulloff_mm: 2\n|)
      [{"name", "R"}, {"axes/x/steps_per_mm", "80"}, {"axes/x/motor0/pulloff_mm", "2"}]
  """
  @spec parse(String.t()) :: [{String.t(), String.t()}]
  def parse(text), do: text |> Yaml.parse() |> Yaml.leaves()

  @doc """
  What changed between two config texts, value by value (`nil` text is an
  empty file): `[%{path, from, to}]`.
  """
  @spec diff_texts(String.t() | nil, String.t()) :: [map]
  def diff_texts(old, new), do: diff_maps(Map.new(parse(old || "")), Map.new(parse(new || "")))

  @doc """
  What changed between two sets of values (`%{path => value}`):
  `[%{path, from, to}]`, `nil` where one side has no value.
  """
  @spec diff_maps(map, map) :: [map]
  def diff_maps(from, to) do
    # (A tuple, not two bindings: in a comprehension a binding to nil
    # filters the element out, and a value missing on one side counts.)
    for path <- Enum.sort(Enum.uniq(Map.keys(from) ++ Map.keys(to))),
        {x, y} = {from[path], to[path]},
        x == nil or y == nil or not same?(x, y),
        do: %{path: path, from: x, to: y}
  end

  @doc "Two values mean the same: numbers as numbers (FluidNC prints 900 as 900.000), text in any case."
  def same?(a, b) do
    case {Float.parse(a), Float.parse(b)} do
      {{x, ""}, {y, ""}} -> abs(x - y) < 1.0e-6
      _ -> String.downcase(String.trim(a)) == String.downcase(String.trim(b))
    end
  end

  @doc "A value that's safe to send as `$/path=value` (one line, no `=`), trimmed."
  def valid_value(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= 64 and String.printable?(value) and
         not String.contains?(value, ["\n", "\r", "="]),
       do: {:ok, value},
       else: {:error, :invalid_value}
  end

  def valid_value(_), do: {:error, :invalid_value}

  def valid_value?(value), do: match?({:ok, _}, valid_value(value))
end
