defmodule CNC.Controllers.Yaml do
  @moduledoc """
  The small part of YAML FluidNC configs use: nested `key: value` maps by
  indentation, no lists. Enough to read a config into a tree, set values by
  path and write it back out (comments are dropped).

  A tree is a list of `{key, {:value, string}}` and `{key, {:map, tree}}`,
  in file order. Paths are lower case, `/`-separated, as FluidNC takes them
  (`axes/x/max_rate_mm_per_min`); keys keep their case in the tree.
  """

  @type tree :: [{String.t(), {:value, String.t()} | {:map, tree}}]

  @line ~r/^(\s*)([^:#\s][^:]*):\s?(.*)$/

  @doc ~S"""
  Read a config's text into a tree.

      iex> CNC.Controllers.Yaml.parse("name: \"R\"\naxes:\n  X:\n    steps_per_mm: 80\n")
      [{"name", {:value, "R"}}, {"axes", {:map, [{"X", {:map, [{"steps_per_mm", {:value, "80"}}]}}]}}]
  """
  @spec parse(String.t()) :: tree
  def parse(text) do
    entries =
      for line <- String.split(text, "\n"),
          not String.starts_with?(String.trim_leading(line), "#"),
          [_, indent, key, value] <- [Regex.run(@line, line)],
          do: {String.length(indent), String.trim(key), unquote_value(String.trim(value))}

    {tree, _} = build(entries, -1)
    tree
  end

  defp build([{depth, key, value} | rest], parent) when depth > parent do
    {node, rest} =
      if value == "" do
        {children, rest} = build(rest, depth)
        {{key, {:map, children}}, rest}
      else
        {{key, {:value, value}}, rest}
      end

    {siblings, rest} = build(rest, parent)
    {[node | siblings], rest}
  end

  defp build(rest, _parent), do: {[], rest}

  @doc "Every value in the tree as `[{path, value}]`, in order."
  @spec leaves(tree) :: [{String.t(), String.t()}]
  def leaves(tree, prefix \\ []) do
    Enum.flat_map(tree, fn
      {key, {:value, v}} -> [{path(prefix, key), v}]
      {key, {:map, children}} -> leaves(children, prefix ++ [String.downcase(key)])
    end)
  end

  defp path(prefix, key), do: Enum.join(prefix ++ [String.downcase(key)], "/")

  @doc """
  Set a value by path (keys matched in any case); missing maps and keys are
  added at the end of their parent.
  """
  @spec put(tree, String.t(), String.t()) :: tree
  def put(tree, path, value), do: put_keys(tree, String.split(path, "/"), value)

  defp put_keys(tree, [key], value) do
    case find_index(tree, key) do
      nil -> tree ++ [{key, {:value, value}}]
      i -> List.update_at(tree, i, fn {k, _} -> {k, {:value, value}} end)
    end
  end

  defp put_keys(tree, [key | rest], value) do
    case find_index(tree, key) do
      nil ->
        tree ++ [{key, {:map, put_keys([], rest, value)}}]

      i ->
        List.update_at(tree, i, fn
          {k, {:map, children}} -> {k, {:map, put_keys(children, rest, value)}}
          {k, {:value, _}} -> {k, {:map, put_keys([], rest, value)}}
        end)
    end
  end

  defp find_index(tree, key) do
    key = String.downcase(key)
    Enum.find_index(tree, fn {k, _} -> String.downcase(k) == key end)
  end

  @doc """
  Keep only the values whose path `keep?` accepts. Maps left empty go,
  except those that were empty to begin with (`kinematics: Cartesian:`,
  which mean something by being there).
  """
  @spec filter(tree, (String.t() -> boolean)) :: tree
  def filter(tree, keep?, prefix \\ []) do
    for {key, node} <- tree,
        kept = filter_node(node, keep?, prefix ++ [String.downcase(key)]),
        kept != nil,
        do: {key, kept}
  end

  defp filter_node({:value, _} = v, keep?, path),
    do: if(keep?.(Enum.join(path, "/")), do: v, else: nil)

  defp filter_node({:map, []} = empty, _keep?, _path), do: empty

  defp filter_node({:map, children}, keep?, path) do
    case filter(children, keep?, path) do
      [] -> nil
      kept -> {:map, kept}
    end
  end

  @doc "Write a tree out as config text."
  @spec render(tree) :: String.t()
  def render(tree), do: IO.iodata_to_binary(render(tree, ""))

  defp render(tree, indent) do
    for {key, node} <- tree do
      case node do
        {:value, v} -> [indent, key, ": ", quote_value(v), "\n"]
        {:map, children} -> [indent, key, ":\n", render(children, indent <> "  ")]
      end
    end
  end

  # Quoted only when YAML would misread it (a comment marker, a ": ").
  defp quote_value(v) do
    if String.contains?(v, [" #", ": "]) or String.starts_with?(v, ["#", "\"", "'"]),
      do: ~s("#{String.replace(v, "\"", "\\\"")}"),
      else: v
  end

  defp unquote_value(<<q, rest::binary>> = value) when q in [?", ?'] do
    if rest != "" and String.ends_with?(rest, <<q>>),
      do: String.slice(rest, 0..-2//1),
      else: value
  end

  defp unquote_value(value), do: value
end
