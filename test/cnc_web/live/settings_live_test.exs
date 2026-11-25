defmodule CNCWeb.SettingsLiveTest do
  use CNCWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {conn, m, program} = with_instance(conn)
    %{conn: conn, m: m, program: program}
  end

  test "the jog trail is off by default; turning it on reaches the machine screen", %{conn: conn} do
    {:ok, machine, _} = live(conn, ~p"/")
    assert has_element?(machine, "#bed[data-trail=false]")

    {:ok, settings, _} = live(conn, ~p"/settings")
    assert has_element?(settings, "#nav-settings[aria-current=page]")
    assert has_element?(settings, "#jog-trail-off[aria-pressed=true]")

    settings |> element("#jog-trail-on") |> render_click()
    assert has_element?(settings, "#jog-trail-on[aria-pressed=true]")
    assert eventually(fn -> has_element?(machine, "#bed[data-trail=true]") end)
  end

  test "CNCApp.Settings refuses unknown keys and wrong types", %{conn: _} do
    db = :"settings_db_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "#{db}")
    start_supervised!({CubDB, data_dir: dir, name: db})
    on_exit(fn -> File.rm_rf(dir) end)

    assert CNCApp.Settings.all(db) == %{jog_trail: false}
    assert {:error, :unknown} = CNCApp.Settings.put(db, :nope, true)
    assert {:error, :invalid} = CNCApp.Settings.put(db, :jog_trail, "yes")
    assert {:ok, %{jog_trail: true}} = CNCApp.Settings.put(db, :jog_trail, true)
    assert CNCApp.Settings.get(db, :jog_trail)
  end

  defp eventually(fun, timeout \\ 2000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
