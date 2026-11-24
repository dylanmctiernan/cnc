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
    approve(view)
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

    # Asked first, with what changes
    assert has_element?(view, "#approve-modal #approve-diffs li", "axes/x/max_rate_mm_per_min")
    approve(view)

    assert has_element?(view, "#set-x-max_rate_mm_per_min[value='2500']")
    assert has_element?(view, "#set-y-acceleration_mm_per_sec2.is-error")

    view
    |> form("#other-form", other: %{path: "stepping/engine", value: "RMT"})
    |> render_submit()

    approve(view)

    assert has_element?(view, ".cnc-set-error", "wiring")
    refute has_element?(view, "#config-drift")
  end

  test "cancelling the dialog changes nothing", %{conn: conn, id: id} do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")
    view |> element("#edit-current") |> render_click()

    view
    |> form("#axes-form", set: %{"axes/x/max_rate_mm_per_min" => "2000"})
    |> render_submit()

    assert has_element?(view, "#approve-modal", "3000")
    view |> element("#cancel-approve") |> render_click()
    refute has_element?(view, "#approve-modal")
    assert has_element?(view, "#set-x-max_rate_mm_per_min[value='3000']")
  end

  test "make a profile, switch to it; the controllers page shows it", %{conn: conn, id: id} do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")
    view |> form("#new-profile-form", new: %{name: "Fast"}) |> render_submit()
    fast = profile_id(view, "Fast")

    view |> element("#profile-#{fast} button", "Switch to this") |> render_click()
    approve(view)
    assert eventually(fn -> has_element?(view, "#current", "Fast") end, 3000)
    assert eventually(fn -> has_element?(view, "#check-ok") end, 3000)
    assert has_element?(view, "#profiles", "Default")

    {:ok, list, _} = live(conn, ~p"/controllers")
    assert has_element?(list, "#profile-of-#{id}", "Fast")
  end

  test "history: each change with its reason; restoring a version, after its diff", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")

    for rate <- ["2500", "2600"] do
      view |> element("#edit-current") |> render_click()

      view
      |> form("#axes-form", set: %{"axes/x/max_rate_mm_per_min" => rate})
      |> render_submit()

      approve(view)
    end

    assert has_element?(view, "#controller-history #c-v2", "Changed 1 setting in profile Default")
    view |> element("#c-v1 .cnc-rev-head") |> render_click()
    assert has_element?(view, "#c-v1 li", "axes/x/max_rate_mm_per_min")

    view |> element("#c-v1 button", "Restore v1") |> render_click()
    assert has_element?(view, "#approve-modal", "v1")
    approve(view)

    assert eventually(fn -> has_element?(view, "#check-differs") end, 3000)
    assert has_element?(view, "#c-v3", "Restored v1")

    view |> element("#write-profile") |> render_click()
    approve(view)
    assert eventually(fn -> has_element?(view, "#check-ok") end, 3000)

    # The profile's own history
    view |> element("#current-history") |> render_click()
    assert has_element?(view, "#history-#{current_id(view)}", "Changed on the controller")
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

    approve(view)

    assert has_element?(view, ".cnc-set-error", "number")

    # The valid value was saved with the first try: nothing left to ask
    view
    |> form("#edit-profile-#{slow}", set: %{"axes/x/max_rate_mm_per_min" => "1000"})
    |> render_submit()

    refute has_element?(view, "#approve-modal")

    # Stored, not sent: the current settings are unchanged
    assert has_element?(view, "#current-x-max_rate_mm_per_min", "3000")
    assert has_element?(view, "#view-#{slow}-x-max_rate_mm_per_min", "1000")

    view |> element("#profile-#{slow} button", "Diff with current") |> render_click()
    assert has_element?(view, "#diff-#{slow}", "1 setting differs")
    assert has_element?(view, "#diff-#{slow} li", "axes/x/max_rate_mm_per_min")
    assert has_element?(view, "#yaml-#{slow} .y-key", "max_rate_mm_per_min")

    view |> element("#profile-#{slow} button", "Switch to this") |> render_click()
    approve(view)
    assert eventually(fn -> has_element?(view, "#current", "Slow") end, 3000)
    assert eventually(fn -> has_element?(view, "#current-x-max_rate_mm_per_min", "1000") end)
  end

  test "advanced: view the file; your own config, uploaded or pasted, after its diff", %{
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
    |> file_input("#override-form", :config_file, [%{name: "mine.yaml", content: own}])
    |> render_upload("mine.yaml")

    view |> form("#override-form") |> render_submit()
    assert has_element?(view, "#approve-modal", "1500")
    approve(view)
    assert eventually(fn -> has_element?(view, "#check-differs") end, 3000)
    assert has_element?(view, "#check-differs", "wasn't written by the app")
    assert has_element?(view, "#c-v1", "Uploaded mine.yaml")

    # Pasted
    view
    |> form("#override-form", %{
      paste: "name: Pasted\naxes:\n  x:\n    max_rate_mm_per_min: 1400\n"
    })
    |> render_submit()

    assert has_element?(view, "#approve-modal", "1400")
    approve(view)
    assert eventually(fn -> has_element?(view, "#c-v2", "Pasted a config") end, 3000)

    view |> element("#write-profile") |> render_click()
    approve(view)
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

  defp approve(view), do: view |> element("#approve") |> render_click()

  defp current_id(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#current .cnc-ctl-card")
    |> LazyHTML.attribute("id")
    |> hd()
    |> String.replace_prefix("profile-", "")
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
