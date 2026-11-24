defmodule CNCWeb.MachineLiveTest do
  # Drives the application's Machine (Sim-backed), so not async.
  use CNCWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CNC.Machine

  # Start each test locked, as after a fresh connect. Wait for the reset to
  # be seen (:connecting) before waiting for :alarm, or a test that ended in
  # :alarm would race the controller's reboot banner.
  setup do
    Machine.subscribe()
    Machine.jog_stop()
    Machine.reset()
    assert_receive {:machine, %{state: :connecting}}, 1000
    assert_receive {:machine, %{state: :alarm}}, 1000
    Phoenix.PubSub.unsubscribe(CNC.PubSub, "machine")
    :ok
  end

  test "shows the lock and unlocks", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Locked"
    assert html =~ "Simulator"

    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> render(view) =~ "Ready" end)
    refute render(view) =~ "cnc-lock"
  end

  test "keyboard jog events drive the machine and stream positions", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> Machine.status().state == :idle end)

    render_hook(view, "jog", %{"x" => 1, "y" => 1, "tier" => "fast"})
    assert Machine.status().state == :jogging
    assert_push_event(view, "pos", %{state: :jogging, jog: [1, 1]})

    for _ <- 1..4 do
      Process.sleep(50)
      render_hook(view, "jog_heartbeat", %{})
    end

    render_hook(view, "jog_stop", %{})
    assert Machine.status().state == :idle
    assert eventually(fn -> elem(Machine.status().mpos, 0) > 0 end)
  end

  test "rejects malformed jog input", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> Machine.status().state == :idle end)

    render_hook(view, "jog", %{"x" => 5, "y" => 0, "tier" => "fast"})
    render_hook(view, "jog", %{"x" => 1, "y" => 0, "tier" => "ludicrous"})
    assert Machine.status().state == :idle
  end

  test "step pad moves by the chosen step", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> render(view) =~ "Ready" end)
    {x0, y0, _} = Machine.status().mpos

    view |> element("button[phx-value-mm='1']") |> render_click()
    view |> element("button", "Y+") |> render_click()

    assert eventually(fn ->
             {x, y, _} = Machine.status().mpos
             x == x0 and abs(y - (y0 + 1)) < 0.001
           end)
  end

  test "Esc stops and holds; help toggles", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    refute render(view) =~ "Stop and hold"
    render_hook(view, "toggle_help", %{})
    assert render(view) =~ "Stop and hold"
    assert render_hook(view, "stop", %{})
  end

  defp eventually(fun, timeout \\ 2000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
