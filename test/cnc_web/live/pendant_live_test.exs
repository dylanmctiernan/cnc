defmodule CNCWeb.PendantLiveTest do
  use CNCWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CNC.Machine

  setup %{conn: conn} do
    {conn, m, _program} = with_instance(conn)
    assert eventually(fn -> Machine.status(m).state == :alarm end)
    %{conn: conn, m: m}
  end

  test "state and Stop at the top; Unlock while locked", %{conn: conn, m: m} do
    {:ok, view, _} = live(conn, ~p"/pendant")
    assert has_element?(view, "#pendant-state", "Locked")
    assert has_element?(view, "#pendant-stop")
    assert has_element?(view, "#pendant-joystick[data-enabled=false]")

    assert has_element?(view, "#pendant-locked")
    view |> element("#pendant-action[data-action=unlock]") |> render_click()
    assert eventually(fn -> Machine.status(m).state == :idle end)
    assert eventually(fn -> has_element?(view, "#pendant-state", "Ready") end)
    refute has_element?(view, "#pendant-locked")
    assert has_element?(view, "#pendant-joystick[data-enabled=true]")
  end

  test "jog speed, a jog, and Stop", %{conn: conn, m: m} do
    {:ok, view, _} = live(conn, ~p"/pendant")
    :ok = Machine.unlock(m)
    assert eventually(fn -> Machine.status(m).state == :idle end)

    view |> element("#pendant-tier-fast") |> render_click()
    assert has_element?(view, "#pendant-tier-fast.is-on")
    assert has_element?(view, "#pendant-joystick[data-tier=fast]")

    render_hook(view, "jog", %{"x" => 0.5, "y" => 0, "z" => 0, "tier" => "fast"})
    assert eventually(fn -> Machine.status(m).state == :jogging end)
    render_hook(view, "jog", %{"x" => 7, "y" => 0, "tier" => "fast"})

    view |> element("#pendant-stop") |> render_click()
    assert eventually(fn -> Machine.status(m).state != :jogging end)
  end

  test "Stop latches a hold; Resume, here on the pendant, releases it", %{conn: conn, m: m} do
    {:ok, view, _} = live(conn, ~p"/pendant")
    :ok = Machine.unlock(m)
    assert eventually(fn -> Machine.status(m).state == :idle end)
    assert eventually(fn -> has_element?(view, "#pendant-action[disabled]") end)

    view |> element("#pendant-stop") |> render_click()
    assert eventually(fn -> has_element?(view, "#pendant-state", "On hold") end)
    assert has_element?(view, "#pendant-held")

    view |> element("#pendant-action[data-action=resume]") |> render_click()
    assert eventually(fn -> Machine.status(m).state == :idle end)
    assert eventually(fn -> has_element?(view, "#pendant-state", "Ready") end)
    refute has_element?(view, "#pendant-held")
  end

  test "linked from the workstation's rail, and back", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/configuration")

    {:ok, pendant, _} =
      view |> element("#nav-pendant") |> render_click() |> follow_redirect(conn, ~p"/pendant")

    assert has_element?(pendant, "#pendant-workstation")
  end

  defp eventually(fun, timeout \\ 2000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
