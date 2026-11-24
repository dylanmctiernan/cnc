defmodule CNCWeb.ConfigLiveTest do
  use CNCWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CNC.{Controllers, Machine}
  alias CNC.Configuration.{FluidNC, Profiles}

  setup %{conn: conn} do
    {conn, m, _program} = with_instance(conn)
    assert eventually(fn -> Machine.status(m).state == :alarm end)
    cnc = CNCWeb.Instance.from_session(get_session(conn))
    [active] = Controllers.list(cnc.controllers)
    %{conn: conn, m: m, cnc: cnc, id: active.id}
  end

  test "reached from the machine screen and the controllers page", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    {:ok, _view, _} =
      view
      |> element("#nav-configuration")
      |> render_click()
      |> follow_redirect(conn, ~p"/configuration")

    {:ok, view, _} = live(conn, ~p"/controllers")

    {:ok, config, _} =
      view
      |> element("#nav-configuration")
      |> render_click()
      |> follow_redirect(conn, ~p"/configuration")

    assert has_element?(config, "#config-controller", "Fake sim")
  end

  test "tabs, each with its own address; the status strip on every one", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/configuration")
    assert has_element?(view, "#tab-panel-profiles")
    assert has_element?(view, "#in-use", "Default")
    assert has_element?(view, "#status-file", "In step")

    for tab <- ~w(build wiring file history) do
      view |> element("#tab-#{tab}") |> render_click()
      assert_patch(view, "/configuration/#{tab}")
      assert has_element?(view, "#tab-panel-#{tab}")
      assert has_element?(view, "#in-use")
    end

    # The fake sim has nothing wired; its build is travel only
    {:ok, view, _} = live(conn, ~p"/configuration/wiring")
    assert has_element?(view, "#no-wiring")
    {:ok, view, _} = live(conn, ~p"/configuration/build")
    assert has_element?(view, "#view-build-x-max_travel_mm", "1250")
  end

  test "edits in two tabs are staged, reviewed together and applied at once", %{
    conn: conn,
    m: m,
    cnc: cnc
  } do
    {:ok, view, _} = live(conn, ~p"/configuration")
    pid = selected_id(cnc)

    view |> element("#edit-#{pid}") |> render_click()

    view
    |> form("#edit-profile-#{pid}", set: %{"axes/x/max_rate_mm_per_min" => "2500"})
    |> render_submit(%{intent: "stage"})

    # Staged, not applied
    assert has_element?(view, "#pending-bar", "1 value staged")
    assert has_element?(view, "#tab-profiles .ui-count", "1")
    assert has_element?(view, "#view-#{pid}-x-max_rate_mm_per_min.is-staged", "2500")
    assert FluidNC.get(m, "axes/x/max_rate_mm_per_min") == {:ok, "3000"}

    {:ok, view, _} = live(conn, ~p"/configuration/build")
    # Every screen sees the same changeset
    assert has_element?(view, "#pending-bar", "1 value staged")
    view |> element("#edit-build-button") |> render_click()

    view
    |> form("#edit-build",
      set: %{"axes/x/max_travel_mm" => "1000", "axes/y/max_travel_mm" => "900"}
    )
    |> render_submit(%{intent: "stage"})

    assert has_element?(view, "#pending-bar", "3 values staged")

    view |> element("#review-staged") |> render_click()
    assert has_element?(view, "#review-modal", "profile Default")
    assert has_element?(view, "#review-modal", "build")
    # Drop one before applying

    view |> element("#review-modal li[id$='axes-y-max_travel_mm'] button") |> render_click()
    refute has_element?(view, "#review-modal li", "axes/y/max_travel_mm")

    view |> element("#apply-staged") |> render_click()
    refute has_element?(view, "#pending-bar")
    assert FluidNC.get(m, "axes/x/max_rate_mm_per_min") == {:ok, "2500"}
    assert FluidNC.get(m, "axes/x/max_travel_mm") == {:ok, "1000"}

    {:ok, view, _} = live(conn, ~p"/configuration/history")
    assert has_element?(view, "#c-v1", "Changed 2 values (the build, profile Default)")
  end

  test "Apply now reviews just those edits; a bad value stays in the form", %{
    conn: conn,
    m: m,
    cnc: cnc
  } do
    {:ok, view, _} = live(conn, ~p"/configuration")
    pid = selected_id(cnc)
    view |> element("#edit-#{pid}") |> render_click()

    view
    |> form("#edit-profile-#{pid}", set: %{"axes/y/max_rate_mm_per_min" => "1\n$H"})
    |> render_submit(%{intent: "stage"})

    assert has_element?(view, "#set-#{pid}-y-max_rate_mm_per_min.is-error")
    refute has_element?(view, "#pending-bar")

    view
    |> form("#edit-profile-#{pid}", set: %{"axes/y/max_rate_mm_per_min" => "2800"})
    |> render_submit(%{intent: "now"})

    assert has_element?(view, "#review-modal", "2800")
    view |> element("#apply-staged") |> render_click()
    assert FluidNC.get(m, "axes/y/max_rate_mm_per_min") == {:ok, "2800"}
  end

  test "discarding drops everything staged", %{conn: conn, m: m, cnc: cnc} do
    {:ok, view, _} = live(conn, ~p"/configuration")
    pid = selected_id(cnc)
    view |> element("#edit-#{pid}") |> render_click()

    view
    |> form("#edit-profile-#{pid}", set: %{"axes/x/max_rate_mm_per_min" => "2000"})
    |> render_submit(%{intent: "stage"})

    view |> element("#discard-staged") |> render_click()
    refute has_element?(view, "#pending-bar")
    assert FluidNC.get(m, "axes/x/max_rate_mm_per_min") == {:ok, "3000"}
  end

  test "another profile: staged edits are stored only; switching is approved from its diff",
       %{conn: conn, m: m, cnc: cnc} do
    {:ok, view, _} = live(conn, ~p"/configuration")
    view |> form("#new-profile-form", new: %{name: "Slow"}) |> render_submit()
    slow = Enum.find(Profiles.list(cnc.db), &(&1.name == "Slow")).id

    view |> element("#edit-#{slow}") |> render_click()

    view
    |> form("#edit-profile-#{slow}", set: %{"axes/x/max_rate_mm_per_min" => "1000"})
    |> render_submit(%{intent: "now"})

    assert has_element?(view, "#review-modal", "profile Slow")
    view |> element("#apply-staged") |> render_click()
    # Stored in Slow; the controller runs Default still
    assert FluidNC.get(m, "axes/x/max_rate_mm_per_min") == {:ok, "3000"}

    view |> element("#profile-#{slow} button", "Diff with selected") |> render_click()
    assert has_element?(view, "#diff-#{slow}", "1 value differs")

    view |> element("#profile-#{slow} button", "Switch to this") |> render_click()
    assert has_element?(view, "#approve-modal", "1000")
    view |> element("#approve") |> render_click()
    assert eventually(fn -> has_element?(view, "#in-use", "Slow") end, 3000)

    assert eventually(
             fn -> FluidNC.get(m, "axes/x/max_rate_mm_per_min") == {:ok, "1000"} end,
             3000
           )

    {:ok, list, _} = live(conn, ~p"/controllers")
    assert has_element?(list, "#controllers li.is-active dd", "Slow")
  end

  test "file: your own config (pasted), after its diff; then the configuration written back",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/configuration/file")
    view |> element("#view-file") |> render_click()
    assert has_element?(view, "#config-text", "max_rate_mm_per_min")

    view
    |> form("#override-form", %{
      paste: "name: Pasted\naxes:\n  x:\n    max_rate_mm_per_min: 1400\n"
    })
    |> render_submit()

    assert has_element?(view, "#approve-modal", "1400")
    view |> element("#approve") |> render_click()

    assert eventually(
             fn -> has_element?(view, "#check-differs", "wasn't written by the app") end,
             3000
           )

    view |> element("#write-profile") |> render_click()
    view |> element("#approve") |> render_click()
    assert eventually(fn -> has_element?(view, "#check-ok") end, 3000)

    {:ok, view, _} = live(conn, ~p"/configuration/history")
    assert has_element?(view, "#c-v1", "Pasted a config")
    view |> element("#c-v1 .cnc-rev-head") |> render_click()
    view |> element("#c-v1 button", "Restore v1") |> render_click()
    assert has_element?(view, "#approve-modal", "v1")
  end

  test "with no controller in use it says so; it follows the one connected", %{
    conn: conn,
    cnc: cnc,
    m: m
  } do
    :ok = Controllers.deactivate(cnc.controllers)
    {:ok, view, _} = live(conn, ~p"/configuration")
    assert has_element?(view, "#config-not-connected")

    {:ok, other} = Controllers.add(cnc.controllers, %{name: "Other", board: :fake_sim})
    :ok = Controllers.select(cnc.controllers, other.id)
    assert eventually(fn -> Machine.status(m).state == :alarm end, 3000)
    assert eventually(fn -> has_element?(view, "#config-controller", "Other") end, 3000)
  end

  defp selected_id(cnc) do
    assert eventually(fn -> Profiles.selected(cnc.db) != nil end)
    Profiles.selected(cnc.db).id
  end

  defp eventually(fun, timeout \\ 2000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
