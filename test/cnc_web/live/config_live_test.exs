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
    # The controller's own file isn't what the app writes (it leaves settings out)
    assert has_element?(view, "#check-differs", "wasn't written by the app")
    view |> element("#write-profile") |> render_click()
    assert eventually(fn -> has_element?(view, "#check-ok") end, 3000)
    assert has_element?(view, "#current", "Default")
    assert has_element?(view, "#current-x-max_rate_mm_per_min", "3000")
    refute has_element?(view, "#axes-form")

    view |> element("#edit-current") |> render_click()
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
    assert eventually(fn -> has_element?(view, "#current", "Fast") end, 3000)
    assert eventually(fn -> has_element?(view, "#check-ok") end, 3000)
    assert has_element?(view, "#profiles", "Default")

    {:ok, list, _} = live(conn, ~p"/controllers")
    assert has_element?(list, "#profile-of-#{id}", "Fast")
  end

  test "an earlier version restored: the file differs; write the profile back", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")
    view |> element("#edit-current") |> render_click()

    view
    |> form("#axes-form", set: %{"axes/x/max_rate_mm_per_min" => "2500"})
    |> render_submit()

    view |> element("#advanced summary") |> render_click()
    view |> element("#version-0 button", "Restore") |> render_click()
    assert eventually(fn -> has_element?(view, "#check-differs") end, 3000)
    assert has_element?(view, "#diff-axes-x-max_rate_mm_per_min")

    view |> element("#write-profile") |> render_click()
    assert eventually(fn -> has_element?(view, "#check-ok") end, 3000)
  end

  test "other profiles: view, edit (stored only), then switch to it", %{conn: conn, id: id} do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")
    assert has_element?(view, "#no-other-profiles")
    view |> form("#new-profile-form", new: %{name: "Slow"}) |> render_submit()
    slow = profile_id(view, "Slow")

    view |> element("#profile-#{slow} button", "View") |> render_click()
    assert has_element?(view, "#view-#{slow}-x-max_rate_mm_per_min", "3000")

    view |> element("#profile-#{slow} button", "Edit") |> render_click()

    view
    |> form("#edit-profile-#{slow}",
      set: %{"axes/x/max_rate_mm_per_min" => "1000", "axes/y/max_rate_mm_per_min" => "fast"}
    )
    |> render_submit()

    assert has_element?(view, ".cnc-set-error", "number")

    view
    |> form("#edit-profile-#{slow}", set: %{"axes/x/max_rate_mm_per_min" => "1000"})
    |> render_submit()

    # Stored, not sent: the current settings are unchanged
    assert has_element?(view, "#current-x-max_rate_mm_per_min", "3000")
    assert has_element?(view, "#view-#{slow}-x-max_rate_mm_per_min", "1000")

    view |> element("#profile-#{slow} button", "Switch to this") |> render_click()
    assert eventually(fn -> has_element?(view, "#current", "Slow") end, 3000)
    assert eventually(fn -> has_element?(view, "#current-x-max_rate_mm_per_min", "1000") end)
  end

  test "advanced: view the file; upload your own (it becomes config.yaml)", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")
    refute has_element?(view, "#advanced[open]")
    view |> element("#advanced summary") |> render_click()
    view |> element("#view-file") |> render_click()
    assert has_element?(view, "#advanced[open]")
    assert has_element?(view, "#config-text", "max_rate_mm_per_min")

    own = "name: Mine\naxes:\n  x:\n    max_rate_mm_per_min: 1500\n"

    view
    |> file_input("#upload-form", :config_file, [%{name: "mine.yaml", content: own}])
    |> render_upload("mine.yaml")

    view |> form("#upload-form") |> render_submit()
    assert eventually(fn -> has_element?(view, "#check-differs") end, 3000)
    assert has_element?(view, "#check-differs", "wasn't written by the app")

    view |> element("#write-profile") |> render_click()
    assert eventually(fn -> has_element?(view, "#check-ok") end, 3000)
  end

  test "a controller not in use offers to connect it", %{conn: conn, cnc: cnc, m: m} do
    {:ok, other} = Controllers.add(cnc.controllers, %{name: "Other", board: :fake_sim})
    {:ok, view, _} = live(conn, ~p"/controllers/#{other.id}/configuration")
    assert has_element?(view, "#config-not-connected")

    view |> element("#config-connect") |> render_click()
    assert eventually(fn -> Machine.status(m).state == :alarm end, 3000)
    assert eventually(fn -> has_element?(view, "#current") end, 3000)
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
