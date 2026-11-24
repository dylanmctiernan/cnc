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

  test "lists the files, shows one, saves the running config as a new file", %{conn: conn, id: id} do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")
    assert has_element?(view, "#config-file-config-yaml.is-active")

    view |> element("#config-file-config-yaml button", "View") |> render_click()
    assert has_element?(view, "#config-text", "name: Fake sim")

    view |> form("#save-as-form", save: %{name: "bad name"}) |> render_submit()
    assert has_element?(view, "#config-error")

    view |> form("#save-as-form", save: %{name: "fast"}) |> render_submit()
    assert has_element?(view, "#config-file-fast-yaml")
    refute has_element?(view, "#config-file-fast-yaml.is-active")

    view |> element("#config-file-fast-yaml button", "Delete") |> render_click()
    refute has_element?(view, "#config-file-fast-yaml")
  end

  test "switch config: the controller restarts and the new file is loaded", %{conn: conn, id: id} do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")
    view |> form("#save-as-form", save: %{name: "fast"}) |> render_submit()

    view |> element("#config-file-fast-yaml button", "Use this config") |> render_click()
    assert eventually(fn -> has_element?(view, "#config-file-fast-yaml.is-active") end, 3000)
  end

  test "change axis settings live, see them unsaved, undo one, save the rest", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _} = live(conn, ~p"/controllers/#{id}/configuration")
    assert has_element?(view, "#set-x-max_rate_mm_per_min[value='3000']")
    refute has_element?(view, "#config-changes")

    view
    |> form("#axes-form",
      set: %{"axes/x/max_rate_mm_per_min" => "2500", "axes/y/acceleration_mm_per_sec2" => "fast"}
    )
    |> render_submit()

    assert has_element?(view, "#set-x-max_rate_mm_per_min.is-changed")
    assert has_element?(view, "#set-y-acceleration_mm_per_sec2.is-error")
    assert has_element?(view, "#change-axes-x-max_rate_mm_per_min")

    view
    |> form("#other-form", other: %{path: "$/axes/z/max_travel_mm", value: "90"})
    |> render_submit()

    assert has_element?(view, "#change-axes-z-max_travel_mm")

    view |> element("#change-axes-z-max_travel_mm button", "Undo") |> render_click()
    refute has_element?(view, "#change-axes-z-max_travel_mm")

    view |> element("#save-changes") |> render_click()
    refute has_element?(view, "#config-changes")
    assert has_element?(view, "#config-history #version-0")
    assert has_element?(view, "#set-x-max_rate_mm_per_min[value='2500']")
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

  defp eventually(fun, timeout \\ 2000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
