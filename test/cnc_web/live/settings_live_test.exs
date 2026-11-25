defmodule CNCWeb.SettingsLiveTest do
  use CNCWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {conn, m, program} = with_instance(conn)
    %{conn: conn, m: m, program: program}
  end

  test "the trail is off by default; turning it on reaches the machine screen", %{conn: conn} do
    {:ok, machine, _} = live(conn, ~p"/")
    assert has_element?(machine, "#bed[data-trail=false]")

    {:ok, settings, _} = live(conn, ~p"/settings")
    assert has_element?(settings, "#nav-settings[aria-current=page]")
    assert has_element?(settings, "#trail-off[aria-pressed=true]")

    settings |> element("#trail-on") |> render_click()
    assert has_element?(settings, "#trail-on[aria-pressed=true]")
    assert eventually(fn -> has_element?(machine, "#bed[data-trail=true]") end)
  end

  test "CNCApp.Settings refuses unknown keys and wrong types", %{conn: _} do
    db = :"settings_db_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "#{db}")
    start_supervised!({CubDB, data_dir: dir, name: db})
    on_exit(fn -> File.rm_rf(dir) end)

    assert CNCApp.Settings.all(db) == %{trail: false}
    assert {:error, :unknown} = CNCApp.Settings.put(db, :nope, true)
    assert {:error, :invalid} = CNCApp.Settings.put(db, :trail, "yes")
    assert {:ok, %{trail: true}} = CNCApp.Settings.put(db, :trail, true)
    assert CNCApp.Settings.get(db, :trail)
  end

  defp eventually(fun, timeout \\ 2000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
