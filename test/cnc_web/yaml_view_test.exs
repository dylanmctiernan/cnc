defmodule CNCWeb.YamlViewTest do
  use ExUnit.Case, async: true
  doctest CNCWeb.YamlView

  test "every board's config highlights without losing a character" do
    for board <- CNC.Boards.ids() do
      text = CNC.Boards.config(board)
      html = CNCWeb.YamlView.highlight(text) |> Phoenix.HTML.safe_to_string()
      plain = html |> String.replace(~r/<[^>]+>/, "") |> Phoenix.HTML.html_escape() |> elem(1)
      assert html =~ ~s(<span class="y-pin">) or board == :fake_sim
      assert plain |> IO.iodata_to_binary() |> unescape() == text |> unescape_noop()
    end
  end

  defp unescape(s),
    do:
      s
      |> String.replace("&amp;lt;", "<")
      |> String.replace("&amp;gt;", ">")
      |> String.replace("&amp;quot;", "\"")
      |> String.replace("&amp;#39;", "'")
      |> String.replace("&amp;amp;", "&")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&#39;", "'")
      |> String.replace("&amp;", "&")

  defp unescape_noop(s), do: s
end
