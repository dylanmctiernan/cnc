defmodule CNCWeb.PinTest do
  # Changes global app config, so not async.
  use CNCWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Application.put_env(:cnc, :access_pin, "4321")
    on_exit(fn -> Application.delete_env(:cnc, :access_pin) end)
  end

  test "without the PIN, pages redirect to /pin", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/")) == ~p"/pin"
    assert html_response(get(conn, ~p"/pin"), 200) =~ ~s(id="pin-form")
  end

  test "a wrong PIN is refused", %{conn: conn} do
    conn = post(conn, ~p"/pin", pin: "0000")
    assert html_response(conn, 401) =~ "Wrong PIN"
  end

  test "the right PIN grants this browser access", %{conn: conn} do
    conn = post(conn, ~p"/pin", pin: "4321")
    assert redirected_to(conn) == ~p"/"

    conn = get(recycle(conn), ~p"/")
    assert html_response(conn, 200) =~ "cnc-bed"
    assert {:ok, _view, _html} = live(conn)
  end

  test "the live connection checks the session too", %{conn: conn} do
    # Bypass the plug: a socket with no PIN in its session is turned away.
    conn = conn |> init_test_session(%{}) |> Phoenix.ConnTest.bypass_through(CNCWeb.Router, [])

    assert {:error, {:redirect, %{to: "/pin"}}} =
             live_isolated(conn, CNCWeb.MachineLive, session: %{})
  end

  test "changing the PIN logs everyone out", %{conn: conn} do
    conn = post(conn, ~p"/pin", pin: "4321")
    Application.put_env(:cnc, :access_pin, "9999")
    assert redirected_to(get(recycle(conn), ~p"/")) == ~p"/pin"
  end

  test "Lock screen: back to the PIN, and the browser's open pages are disconnected", %{
    conn: conn
  } do
    conn = post(conn, ~p"/pin", pin: "4321")
    conn = get(recycle(conn), ~p"/")
    {:ok, view, _} = live(conn)
    assert has_element?(view, "#nav-lock[data-method=delete]")

    socket_id = get_session(conn, :live_socket_id)
    CNCWeb.Endpoint.subscribe(socket_id)
    conn = delete(recycle(conn), ~p"/pin")
    assert redirected_to(conn) == ~p"/pin"
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^socket_id}

    assert redirected_to(get(recycle(conn), ~p"/")) == ~p"/pin"
  end

  test "no PIN configured: open access", %{conn: conn} do
    Application.delete_env(:cnc, :access_pin)
    html = html_response(get(conn, ~p"/"), 200)
    assert html =~ "cnc-bed"
    refute html =~ ~s(id="nav-lock")
    assert redirected_to(get(conn, ~p"/pin")) == ~p"/"
  end
end
