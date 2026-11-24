defmodule CNCWeb.MachineLiveTest do
  # Drives the application's Machine (fake-sim-backed), so not async.
  use CNCWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CNC.Machine

  # Start each test locked, as after a fresh connect. Poll for :connecting
  # (it lasts until the next status poll) before waiting for :alarm, or a
  # test that ended in :alarm would race the controller's reboot banner.
  # Broadcasts are throttled and may skip it, so poll the state directly.
  setup do
    Machine.jog_stop()
    Machine.reset()
    assert eventually(fn -> Machine.status().state == :connecting end, 1000, 5)
    assert eventually(fn -> Machine.status().state == :alarm end)
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
    assert_push_event(view, "pos", %{state: :jogging, jog: [1, 1, 0]})

    for _ <- 1..4 do
      Process.sleep(50)
      render_hook(view, "jog_heartbeat", %{})
    end

    render_hook(view, "jog_stop", %{})
    assert Machine.status().state == :idle
    assert eventually(fn -> elem(Machine.status().mpos, 0) > 0 end)
  end

  test "Z: Page key jogs and Z steps", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> render(view) =~ "Ready" end)
    {_, _, z0} = Machine.status().mpos

    # At the top of Z travel already: down works, up is clamped.
    view |> element("button[phx-value-mode=step]") |> render_click()
    view |> element("button[phx-value-mm='1']") |> render_click()
    view |> element("button[phx-value-axis=z]") |> render_click()
    view |> element(".cnc-pendant-btn", "Z−") |> render_click()
    assert eventually(fn -> abs(elem(Machine.status().mpos, 2) - (z0 - 1)) < 0.001 end)

    render_hook(view, "jog", %{"x" => 0, "y" => 0, "z" => -1, "tier" => "fast"})
    assert Machine.status().jog == {0, 0, -1}
    assert_push_event(view, "pos", %{jog: [0, 0, -1]})
    render_hook(view, "jog_stop", %{})
  end

  test "joystick: analog jog events drive the machine proportionally", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ ~s(phx-hook="Joystick")
    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> Machine.status().state == :idle end)

    render_hook(view, "jog", %{"x" => 0.5, "y" => -0.24, "z" => 0, "tier" => "normal"})
    assert Machine.status().jog == {0.5, -0.24, 0}
    render_hook(view, "jog", %{"x" => 0, "y" => 0, "z" => 0.3, "tier" => "normal"})
    assert Machine.status().jog == {0, 0, 0.3}
    render_hook(view, "jog_stop", %{})
    assert Machine.status().state == :idle
  end

  test "type a work position without moving", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> Machine.status().state == :idle and Machine.status().wpos end)
    mpos = Machine.status().mpos

    view |> element(~s|.cnc-num--edit[phx-value-axis="x"]|) |> render_click()
    assert has_element?(view, "#work-dialog", "Set X position")
    # Starts empty (current value as the placeholder): Set waits for a number.
    assert has_element?(view, "#work-dialog button[type=submit][disabled]")

    # The preview says where the work zero lands, in machine terms.
    # A value that would put the work zero off the machine is refused as you type.
    html = view |> form("#work-form", %{value: "99999"}) |> render_change()
    assert html =~ "off the machine"
    assert has_element?(view, "#work-dialog button[type=submit][disabled]")

    # ± flips the sign (iPhone decimal keypads have no minus key).
    view |> form("#work-form", %{value: "12,5"}) |> render_change()
    html = view |> element("#work-dialog button", "±") |> render_click()
    assert html =~ ~s(value="-12,5")

    # -12.5 here: the work zero is 12.5 mm to the tool's right, on the bed.
    html = view |> form("#work-form", %{value: "-12,5"}) |> render_change()
    assert html =~ "X0 will be 12.5 mm to the right of the tool. Nothing moves."

    view |> form("#work-form", %{value: "-12,5"}) |> render_submit()
    refute has_element?(view, "#work-dialog")

    assert eventually(fn ->
             match?({wx, _, _} when abs(wx + 12.5) < 0.001, Machine.status().wpos)
           end)

    assert Machine.status().mpos == mpos

    # Not a number: says so, stays open.
    view |> element(~s|.cnc-num--edit[phx-value-axis="y"]|) |> render_click()
    view |> form("#work-form", %{value: "abc"}) |> render_submit()
    assert has_element?(view, "#work-dialog .cnc-set-error", "Type a number")
  end

  test "tapping the work zero row sets it on the bed; machine positions aren't editable", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> Machine.status().state == :idle and Machine.status().wpos end)

    view |> element(".cnc-dro-head button[phx-value-frame=machine]") |> render_click()
    # The machine position isn't editable; the work zero row is.
    refute has_element?(view, ".cnc-num--edit")
    view |> element(~s|.cnc-dro .cnc-zero-val[phx-value-axis="x"]|) |> render_click()
    assert has_element?(view, "#work-dialog", "Set X work zero")
    assert has_element?(view, "#work-dialog", "Work zero at machine X =")

    html = view |> form("#work-form", %{value: "2000"}) |> render_change()
    assert html =~ "off the machine"

    view |> form("#work-form", %{value: "300"}) |> render_submit()
    refute has_element?(view, "#work-dialog")
    assert eventually(fn -> match?({x, _, _} when abs(x - 300) < 0.001, Machine.status().wco) end)
  end

  test "work coordinates: zero X/Y, move, go back", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> render(view) =~ "Ready" end)
    assert eventually(fn -> render(view) =~ "Work position" end)
    {x0, y0, _} = Machine.status().mpos

    view |> element("button", "Zero X/Y") |> render_click()

    assert eventually(fn ->
             {wx, wy, _} = Machine.status().wpos
             abs(wx) < 1.0e-6 and abs(wy) < 1.0e-6
           end)

    view |> element("button[phx-value-mode=step]") |> render_click()
    view |> element("button[phx-value-mm='10']") |> render_click()
    view |> element(".cnc-pendant-btn", "X+") |> render_click()
    # Work = machine - offset, in floats: compare with a tolerance.
    assert eventually(
             fn ->
               {wx, wy, _} = Machine.status().wpos
               abs(wx - 10) < 1.0e-6 and abs(wy) < 1.0e-6
             end,
             3000
           )

    assert eventually(fn -> render(view) =~ "10.00" end)

    # Enabled once the step has finished and the view has caught up.
    assert eventually(fn -> not Machine.status().moving? end, 3000)
    assert eventually(fn -> not has_element?(view, "button[disabled]", "Go to X0 Y0") end, 3000)
    view |> element("button", "Go to X0 Y0") |> render_click()
    # Z lifts first at 10 mm/s, and earlier tests may have left Z far down.
    # Within the clamp's micron inset when the work zero is on a travel edge.
    assert eventually(
             fn ->
               {x, y, z} = Machine.status().mpos
               abs(x - x0) <= 0.01 and abs(y - y0) <= 0.01 and z >= -1.01
             end,
             15_000
           )

    view |> element(".cnc-dro button[phx-value-frame=machine]") |> render_click()
    assert render(view) =~ "Machine position"
  end

  test "shows that it's a simulator, and which firmware", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert eventually(fn -> has_element?(view, ".cnc-sim", "Simulator") end)
    assert eventually(fn -> render(view) =~ "CNC FakeSim 1.1h.cnc-sim" end)
  end

  test "touch layouts: the dock's Stop cancels a jog; More holds the secondary actions", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> Machine.status().state == :idle end)

    render_hook(view, "jog", %{"x" => 1, "y" => 0, "tier" => "normal"})
    assert Machine.status().state == :jogging
    view |> element(".cnc-dock button", "Stop") |> render_click()
    assert Machine.status().state == :idle

    view |> element(".cnc-more > button", "Menu") |> render_click()
    assert has_element?(view, ".cnc-more a", "Settings")
    assert has_element?(view, ".cnc-more button", "Clear trail")
    view |> element(".cnc-more button", "Reset controller") |> render_click()
    refute has_element?(view, "#more-menu")
  end

  test "controller: Zero mode zeroes axes and switches work/machine", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> Machine.status().state == :idle end)

    assert eventually(fn -> render(view) =~ "Work position" end)
    view |> element("button[phx-value-mode=zero]") |> render_click()

    assert eventually(fn ->
             not has_element?(view, ".cnc-zero button[phx-value-axes=xy][disabled]")
           end)

    view |> element(".cnc-zero button[phx-value-axes=xy]") |> render_click()

    assert eventually(fn ->
             match?({wx, wy, _} when abs(wx) < 0.001 and abs(wy) < 0.001, Machine.status().wpos)
           end)

    view |> element(".cnc-zero button[phx-value-frame=machine]") |> render_click()
    assert has_element?(view, ".cnc-zero button[phx-value-frame=machine][aria-pressed=true]")

    view |> element("button[phx-value-mode=joystick]") |> render_click()
    refute has_element?(view, ".cnc-zero")
    assert has_element?(view, "#joystick")
  end

  test "Add to Home Screen: manifest and Apple tags", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(rel="manifest")
    assert html =~ "viewport-fit=cover"
    assert html =~ ~s(name="apple-mobile-web-app-capable" content="yes")

    assert conn |> recycle() |> get("/manifest.webmanifest") |> response(200) =~
             ~s("display": "standalone")
  end

  test "rejects malformed jog input", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> Machine.status().state == :idle end)

    render_hook(view, "jog", %{"x" => 5, "y" => 0, "tier" => "fast"})
    render_hook(view, "jog", %{"x" => 1, "y" => 0, "tier" => "ludicrous"})
    render_hook(view, "jog", %{"x" => 0, "y" => 0, "z" => 2, "tier" => "fast"})
    render_hook(view, "jog", %{"x" => -1.01, "y" => 0, "tier" => "fast"})
    render_hook(view, "jog", %{"x" => "nope", "y" => 0, "tier" => "fast"})
    assert Machine.status().state == :idle
  end

  test "step pad moves by the chosen step", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> render(view) =~ "Ready" end)
    {x0, y0, _} = Machine.status().mpos

    view |> element("button[phx-value-mode=step]") |> render_click()
    view |> element("button[phx-value-mm='1']") |> render_click()
    view |> element("button[phx-value-axis=y]") |> render_click()
    view |> element(".cnc-pendant-btn", "Y+") |> render_click()

    assert eventually(fn ->
             {x, y, _} = Machine.status().mpos
             x == x0 and abs(y - (y0 + 1)) < 0.001
           end)
  end

  test "Esc stops and holds; keyboard listed", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ".cnc-keys dd", "Stop and hold")
    assert render_hook(view, "stop", %{})
  end

  test "details and console", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#console")

    view |> element(".cnc-actions button", "Console") |> render_click()
    assert has_element?(view, "#console")
    assert render(view) =~ "Controller restarted"

    view |> element(".cnc-lock button", "Unlock") |> render_click()
    assert eventually(fn -> has_element?(view, "#console-log li", "$X") end)
    refute has_element?(view, "#console-log li.is-poll")

    view |> element("#console input[type=checkbox]") |> render_click()
    assert eventually(fn -> has_element?(view, "#console-log li.is-poll") end)

    view |> element("#console-input") |> render_submit(%{"line" => "$$"})
    assert eventually(fn -> has_element?(view, "#console-log li", "$130=") end)

    :ok = Machine.jog({1, 0}, :normal)
    view |> element("#console-input") |> render_submit(%{"line" => "$$"})
    assert render(view) =~ "Can&#39;t send while jogging."
    Machine.jog_stop()

    view |> element("button", "Commands") |> render_click()
    assert has_element?(view, "#console-help button", "G10 L20 P1 X0 Y0")
    assert render(view) =~ "The fake sim understands"

    view |> element("#console-help button", "Ask the controller") |> render_click()
    assert eventually(fn -> has_element?(view, "#console-log li", "[HLP:") end)

    view |> element("button", "Hide commands") |> render_click()
    refute has_element?(view, "#console-help")

    view |> element(".cnc-actions button", "Console") |> render_click()
    refute has_element?(view, "#console")
  end

  test "uploading a G-code file shows its summary, shared with other screens", %{conn: conn} do
    CNC.Program.clear()
    {:ok, view, _} = live(conn, ~p"/")
    {:ok, other, _} = live(conn, ~p"/")

    view |> element("#open-file") |> render_click()
    assert has_element?(view, "#file-dialog")

    text = File.read!("test/fixtures/sample.nc")

    file =
      file_input(view, "#upload-form", :gcode, [
        %{name: "sample.nc", content: text, type: "text/plain"}
      ])

    render_upload(file, "sample.nc")

    assert eventually(fn -> render(view) =~ "227 × 87 mm" end)
    html = render(view)
    assert html =~ "sample.nc"
    assert html =~ "down to Z -6 mm"
    assert html =~ "about 6 min"
    assert html =~ "bit changes aren&#39;t handled yet"

    # The other screen has it too (one program for the whole app).
    assert eventually(fn -> has_element?(other, ".cnc-file-side", "sample.nc") end)

    # Loading zooms the map to the file; the toggle goes back to the whole bed.
    assert has_element?(view, "#zoom-toggle", "Whole bed")
    view |> element("#zoom-toggle") |> render_click()
    assert has_element?(view, "#zoom-toggle", "Zoom to file")

    view |> element("#file-dialog button", "Clear file") |> render_click()
    assert eventually(fn -> not has_element?(other, ".cnc-file-side") end)
  end

  test "a file that would leave the travel says by how much", %{conn: conn} do
    {:ok, _} = CNC.Program.load("big.nc", "G0 X0 Y0\nG1 X5000 F1000\nG1 Y-5000")
    {:ok, view, _} = live(conn, ~p"/")

    assert eventually(fn -> Machine.status().wco != nil end)
    assert eventually(fn -> render(view) =~ "won&#39;t fit" end)
    assert render(view) =~ "past the right edge (X)"
    assert render(view) =~ "past the front edge (Y)"
    CNC.Program.clear()
  end

  test "warns when the controller claims more travel than the machine has", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    :ok = Machine.send_raw("$130=12500")
    assert eventually(fn -> render(view) =~ "X travel of 12500 mm" end)

    # Notes can be closed.
    view |> element("#note-travel button") |> render_click()
    refute has_element?(view, "#note-travel")

    # Put it back for the other tests.
    :ok = Machine.send_raw("$130=1250")
    assert eventually(fn -> Machine.status().travel_issues == [] end)
  end

  defp eventually(fun, timeout \\ 2000, every \\ 20) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(every) && eventually(fun, timeout - every, every)
    end
  end
end
