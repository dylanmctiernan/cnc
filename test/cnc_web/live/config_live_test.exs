defmodule CNCWeb.ConfigLiveTest do
  use CNCWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CNC.{Controllers, Machine}

  setup %{conn: conn} do
    {conn, m, _program} = with_instance(conn)
    assert eventually(fn -> Machine.status(m).state == :alarm end)
    cnc = CNCWeb.Instance.from_session(get_session(conn))
    [active] = Controllers.list(cnc.controllers)
    %{conn: conn, m: m, cnc: cnc, id: active.id}
  end

  test "reached from the controllers page", %{conn: conn, id: id} do
    {:ok, view, _} = live(conn, ~p"/controllers")

    {:ok, _view, _} =
      view
      |> element("#configure-#{id}")
      |> render_click()
      |> follow_redirect(conn, ~p"/controllers/#{id}/configuration")
  end

  test "first visit: the Default profile, in use; change a setting", %{conn: conn, id: id} do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")
    assert has_element?(view, "#in-use", "Default")
    assert has_element?(view, "#check-ok")
    assert has_element?(view, "#profiles li.is-active", "Default")
    assert has_element?(view, "#set-x-max_rate_mm_per_min[value='3000']")

    view
    |> form("#axes-form",
      set: %{
        "axes/x/max_rate_mm_per_min" => "2500",
        "axes/y/acceleration_mm_per_sec2" => "fast"
      }
    )
    |> render_submit()

    assert has_element?(view, "#set-x-max_rate_mm_per_min[value='2500']")
    assert has_element?(view, "#set-y-acceleration_mm_per_sec2.is-error")

    view
    |> form("#other-form", other: %{path: "stepping/engine", value: "RMT"})
    |> render_submit()

    assert has_element?(view, ".cnc-set-error", "wiring")
    refute has_element?(view, "#config-drift")
  end

  test "make a profile, switch to it; the controllers page shows it", %{conn: conn, id: id} do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")
    view |> form("#new-profile-form", new: %{name: "Fast"}) |> render_submit()
    fast = profile_id(view, "Fast")

    view |> element("#profile-#{fast} button", "Switch to this") |> render_click()
    assert eventually(fn -> has_element?(view, "#profile-#{fast}.is-active") end, 3000)
    assert eventually(fn -> has_element?(view, "#check-ok") end, 3000)
    assert has_element?(view, "#in-use", "Fast")

    {:ok, list, _} = live(conn, ~p"/controllers")
    assert has_element?(list, "#profile-of-#{id}", "Fast")
  end

  test "an earlier version restored: the file differs; keep it or write the profile", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")

    view
    |> form("#axes-form", set: %{"axes/x/max_rate_mm_per_min" => "2500"})
    |> render_submit()

    view |> element("#version-0 button", "Restore") |> render_click()
    assert has_element?(view, "#check-differs")
    assert has_element?(view, "#diff-axes-x-max_rate_mm_per_min")

    view |> element("#write-profile") |> render_click()
    assert eventually(fn -> has_element?(view, "#check-ok") end, 3000)

    # A new profile isn't written anywhere until switched to: one file stays
    view |> form("#new-profile-form", new: %{name: "Spare"}) |> render_submit()
    assert has_element?(view, "#config-files li", "config.yaml")
    refute has_element?(view, "#config-files li", "spare")
  end

  test "advanced: view the file; load another directly (an override)", %{
    conn: conn,
    id: id,
    m: m
  } do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")
    refute has_element?(view, "#advanced[open]")
    view |> element("#advanced summary") |> render_click()
    view |> element("#config-file-config-yaml button", "View") |> render_click()
    # Stays open through updates
    assert has_element?(view, "#advanced[open]")
    assert has_element?(view, "#config-text", "max_rate_mm_per_min")

    {:ok, _} = CNC.Controllers.Config.save_running_as(m, "mine.yaml")
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")
    view |> element("#config-file-mine-yaml button", "Use this file directly") |> render_click()
    assert eventually(fn -> has_element?(view, "#check-override") end, 3000)
    refute has_element?(view, "#axes-form")

    view |> element("#write-profile") |> render_click()
    assert eventually(fn -> has_element?(view, "#check-ok") end, 3000)
  end

  test "a controller not in use offers to connect it", %{conn: conn, cnc: cnc, m: m} do
    {:ok, other} = Controllers.add(cnc.controllers, %{name: "Other", board: :fake_sim})
    {:ok, view, _} = live(conn, ~p"/controllers/#{other.id}/configuration")
    assert has_element?(view, "#config-not-connected")

    view |> element("#config-connect") |> render_click()
    assert eventually(fn -> Machine.status(m).state == :alarm end, 3000)
    assert eventually(fn -> has_element?(view, "#config-file-config-yaml") end, 3000)
  end

  test "an unknown controller goes back to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/controllers"}}} =
             live(conn, ~p"/controllers/zzzz/configuration")
  end

  defp profile_id(view, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#profiles li")
    |> Enum.find_value(fn li ->
      if LazyHTML.text(LazyHTML.query(li, ".cnc-ctl-name")) == name,
        do: li |> LazyHTML.attribute("id") |> hd() |> String.replace_prefix("profile-", "")
    end)
  end

  defp eventually(fun, timeout \\ 2000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
