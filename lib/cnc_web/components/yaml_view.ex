defmodule CNCWeb.YamlView do
  @moduledoc """
  A FluidNC config shown as YAML: monospace, small, highlighted (keys,
  numbers, true/false, pins, strings, comments). Highlighting is done here,
  line by line, on escaped text.
  """
  use Phoenix.Component

  attr :text, :string, required: true
  attr :id, :string, default: nil
  attr :rest, :global

  def yaml_view(assigns) do
    ~H"""
    <pre class="cnc-yaml" id={@id} {@rest}><code>{highlight(@text)}</code></pre>
    """
  end

  @doc ~S"""
  The text as safe HTML with highlighting spans.

      iex> CNCWeb.YamlView.highlight("x:\n  rate: 3000 # <b>\n") |> Phoenix.HTML.safe_to_string()
      ~s(<span class="y-key">x</span>:\n  <span class="y-key">rate</span>: <span class="y-num">3000</span> <span class="y-com"># &lt;b&gt;</span>\n)
  """
  def highlight(text) when is_binary(text) do
    html =
      text
      |> String.split("\n")
      |> Enum.map(&line/1)
      |> Enum.intersperse("\n")

    {:safe, html}
  end

  defp line(line) do
    case Regex.run(~r/^(\s*)(#.*)$/, line) do
      [_, indent, comment] ->
        [indent, span("y-com", comment)]

      nil ->
        case Regex.run(~r/^(\s*)([^:#\s][^:]*):(\s*)(.*)$/, line) do
          [_, indent, key, gap, rest] -> [indent, span("y-key", key), ":", gap, value(rest)]
          nil -> esc(line)
        end
    end
  end

  # A value, then perhaps a trailing comment.
  defp value(rest) do
    {v, comment} =
      case Regex.run(~r/^(.*?)(\s+#.*)$/, rest) do
        [_, v, comment] -> {v, comment}
        nil -> {rest, ""}
      end

    [kind(v), comment_span(comment)]
  end

  defp comment_span(""), do: []

  defp comment_span(comment) do
    [lead, text] = Regex.run(~r/^(\s+)(.*)$/, comment, capture: :all_but_first)
    [lead, span("y-com", text)]
  end

  defp kind(""), do: []

  defp kind(v) do
    cond do
      Regex.match?(~r/^-?\d+(\.\d+)?$/, v) -> span("y-num", v)
      String.downcase(v) in ~w(true false) -> span("y-bool", v)
      Regex.match?(~r/^(gpio|i2so|i2c|uart)\.\d+|^no_pin$/i, v) -> span("y-pin", v)
      String.starts_with?(v, ["\"", "'"]) -> span("y-str", v)
      true -> span("y-val", v)
    end
  end

  defp span(class, text), do: [~s(<span class="), class, ~s(">), esc(text), "</span>"]

  defp esc(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
