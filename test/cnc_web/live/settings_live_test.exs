defmodule CNCWeb.SettingsLiveTest do
  use CNCWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CNC.Machine

  # A fresh machine per test (CNCWeb.ConnCase.with_instance/1), so writes
  # don't leak between tests and they run in parallel.
  setup %{conn: conn} do
    {conn, m, _program} = with_instance(conn)
    assert eventually(fn -> Machine.settings(m)[130] != nil end)
    %{conn: conn, m: m}
  end

  test "lists settings by group with names and units", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings")
    assert html =~ "Controller settings"
    assert html =~ "X max travel"
    assert has_element?(view, "#set-130")
  end

  test "edit, review the diff, write, see it saved", %{conn: conn, m: m} do
    {:ok, view, _} = live(conn, ~p"/settings")
    form = "form[id^=settings-form]"

    view |> element(form) |> render_change(%{"s" => %{"130" => "900"}})
    assert render(view) =~ "1 change"
    view |> element("button", "Review changes") |> render_click()
    assert has_element?(view, ".cnc-review-to", "900")

    view |> element("button", "Write 1 setting") |> render_click()
    assert eventually(fn -> render(view) =~ "saved" end)
    assert eventually(fn -> Machine.settings(m)[130] == "900.000" end)
  end

  test "untouched fields aren't validated (the form sends them all)", %{conn: conn, m: m} do
    {:ok, view, _} = live(conn, ~p"/settings")
    current = Machine.settings(m)
    fields = Map.new(current, fn {n, v} -> {Integer.to_string(n), v} end)
    # LiveView marks untouched fields with "_unused_<name>" keys.
    fields = fields |> Map.put("130", "900") |> Map.put("_unused_131", "")
    view |> element("form[id^=settings-form]") |> render_change(%{"s" => fields})
    refute has_element?(view, "button[disabled]", "Review changes")
  end

  test "invalid values block the review", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings")
    view |> element("form[id^=settings-form]") |> render_change(%{"s" => %{"130" => "-5"}})
    assert render(view) =~ "Must be more than 0."
    assert has_element?(view, "button[disabled]", "Review changes")
  end

  defp eventually(fun, timeout \\ 2000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
