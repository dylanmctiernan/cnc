defmodule CNCWeb.ControllersLiveTest do
  use CNCWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CNC.Machine

  setup %{conn: conn} do
    {conn, m, _program} = with_instance(conn)
    assert eventually(fn -> Machine.status(m).state == :alarm end)
    %{conn: conn, m: m}
  end

  test "lists controllers: the one in use, its board and link", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/controllers")
    assert has_element?(view, "#controllers li.is-active", "Fake sim")
    assert has_element?(view, "#controllers li.is-active", "In use, connected")
    assert has_element?(view, "#controllers li.is-active dd", "Fake sim")
  end

  test "add: the board decides which links are offered; USB needs a port", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/controllers")
    view |> element("#add-open") |> render_click()

    # ESP32: USB and Wi-Fi
    assert has_element?(view, "#add-form input[name='add[type]'][value=serial]")
    assert has_element?(view, "#add-form input[name='add[type]'][value=tcp]")

    # The FluidNC sim: only on this computer
    view |> form("#add-form", add: %{board: "fluidnc_sim"}) |> render_change()
    assert has_element?(view, "#add-form input[name='add[type]'][value=fluidnc_sim]")
    refute has_element?(view, "#add-form input[name='add[type]'][value=serial]")

    view |> form("#add-form", add: %{board: "esp32_devkit"}) |> render_change()

    view
    |> form("#add-form", add: %{name: "Bench", board: "esp32_devkit", type: "serial", port: ""})
    |> render_submit()

    assert has_element?(view, "#controllers-error", "Choose the USB port")

    view
    |> form("#add-form",
      add: %{name: "Bench", board: "esp32_devkit", type: "serial", port: "/dev/cu.test"}
    )
    |> render_submit()

    assert has_element?(view, "#controllers li", "Bench")
    assert has_element?(view, "#controllers li", "USB /dev/cu.test")
  end

  test "change a controller's link: USB to Wi-Fi, same controller", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/controllers")
    view |> element("#add-open") |> render_click()

    view
    |> form("#add-form", add: %{name: "6x", board: "six_x", type: "serial", port: "/dev/cu.six"})
    |> render_submit()

    id = controller_id(view, "6x")

    view |> element("#controller-#{id} button", "Change link") |> render_click()
    view |> form("#link-form-#{id}", link: %{type: "tcp"}) |> render_change()
    view |> form("#link-form-#{id}", link: %{type: "tcp", host: "cnc6x.local"}) |> render_submit()

    assert has_element?(view, "#controller-#{id}", "Wi-Fi cnc6x.local:23")
    assert has_element?(view, "#controller-#{id}", "6x CNC Controller")
  end

  test "use another controller; remove one that isn't in use", %{conn: conn, m: m} do
    {:ok, view, _} = live(conn, ~p"/controllers")
    view |> element("#add-open") |> render_click()
    first = controller_id(view, "Fake sim")

    view |> form("#add-form", add: %{board: "fake_sim"}) |> render_change()

    view
    |> form("#add-form", add: %{name: "Fake two", board: "fake_sim", type: "fake_sim"})
    |> render_submit()

    second = controller_id(view, "Fake two")
    view |> element("#controller-#{second} button", "Connect") |> render_click()
    assert eventually(fn -> has_element?(view, "#controller-#{second}.is-active") end)
    assert eventually(fn -> Machine.status(m).state == :alarm end, 3000)

    # The old one can go now; the one in use can't.
    view |> element("#controller-#{first} button", "Remove") |> render_click()
    refute has_element?(view, "#controller-#{first}")
    refute has_element?(view, "#controller-#{second} button", "Remove")
  end

  # A controller card's id, by its name heading.
  defp controller_id(view, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#controllers li")
    |> Enum.find_value(fn li ->
      if LazyHTML.text(LazyHTML.query(li, ".cnc-ctl-name")) == name,
        do: li |> LazyHTML.attribute("id") |> hd() |> String.replace_prefix("controller-", "")
    end)
  end

  test "disconnect the one in use, then every controller can go", %{conn: conn, m: m} do
    {:ok, view, _} = live(conn, ~p"/controllers")
    id = controller_id(view, "Fake sim")
    refute has_element?(view, "#controller-#{id} button", "Remove")

    view |> element("#controller-#{id} button", "Disconnect") |> render_click()
    assert eventually(fn -> Machine.status(m).state == :disconnected end)
    refute has_element?(view, "#controllers li.is-active")

    view |> element("#controller-#{id} button", "Remove") |> render_click()
    assert has_element?(view, "#no-controllers")
  end

  defp eventually(fun, timeout \\ 2000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
