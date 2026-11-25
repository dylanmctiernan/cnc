defmodule CNCWeb.MachineJobLiveTest do
  use CNCWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CNC.Machine

  # A small square at Z-1 (the fake sim's Z travel is -100..0)
  @square "G21 G90\nG0 Z0\nG0 X0 Y0\nG1 Z-1 F600\nG1 X40 F3000\nG1 Y40\nG1 X0\nG1 Y0\nG0 Z0\n"

  setup %{conn: conn} do
    {conn, m, program} = with_instance(conn)
    assert eventually(fn -> Machine.status(m).state == :alarm end)
    :ok = Machine.unlock(m)
    assert eventually(fn -> Machine.status(m).state == :idle and Machine.status(m).wco end)
    %{conn: conn, m: m, program: program}
  end

  test "Start: nothing without a file; with one, a check first, then it runs", %{
    conn: conn,
    m: m,
    program: program
  } do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#bar-resume[disabled]", "Start")

    {:ok, _} = CNC.Program.load("square.nc", @square, server: program)
    assert eventually(fn -> has_element?(view, "#bar-resume:not([disabled])", "Start") end)

    view |> element("#bar-resume") |> render_click()
    assert has_element?(view, "#start-dialog #start-checks li.is-ok")
    view |> element("#cancel-start") |> render_click()
    refute has_element?(view, "#start-dialog")
    assert Machine.status(m).state == :idle

    view |> element("#bar-resume") |> render_click()
    view |> element("#confirm-start") |> render_click()
    assert eventually(fn -> Machine.status(m).state == :running end)
    assert eventually(fn -> has_element?(view, "#job-panel", "square.nc") end)
    # The Auto panel shows the job; no other file can be opened meanwhile
    refute has_element?(view, "#open-file")

    # Hold: the reminder, and the same button resumes
    view |> element("#bar-hold") |> render_click()
    assert eventually(fn -> has_element?(view, "#note-held", "spindle keeps turning") end)
    # Ending the job is offered right there; it asks first
    view |> element("#held-abort") |> render_click()
    assert has_element?(view, "#abort-dialog")
    view |> element("#cancel-abort") |> render_click()
    assert has_element?(view, "#bar-resume:not([disabled])", "Resume")
    view |> element("#bar-resume") |> render_click()

    assert eventually(fn -> Machine.status(m).state == :idle end, 10_000)
    assert eventually(fn -> has_element?(view, "#note-job", "Finished square.nc") end)
    refute has_element?(view, "#job-panel")
  end

  test "Check first: nothing moves, and the Locked banner says how the check went", %{
    conn: conn,
    m: m,
    program: program
  } do
    {:ok, _} = CNC.Program.load("odd.nc", "G21\nG1 X10 F600\nG28\nG1 X20\n", server: program)
    {:ok, view, _} = live(conn, ~p"/")
    assert eventually(fn -> has_element?(view, "#bar-resume:not([disabled])") end)
    before = Machine.status(m).mpos

    view |> element("#bar-resume") |> render_click()
    view |> element("#check-start") |> render_click()

    assert eventually(fn -> Machine.status(m).state == :alarm end, 5000)

    assert eventually(fn ->
             has_element?(view, ".cnc-lock", "Checked odd.nc: 1 line refused") and
               has_element?(view, ".cnc-lock", "doesn't support") and
               has_element?(view, ".cnc-lock", "unlock to carry on")
           end)

    refute has_element?(view, "#note-job")
    assert Machine.status(m).mpos == before
  end

  test "Outline from the pre-start dialog traces the file, then it's Ready again", %{
    conn: conn,
    m: m,
    program: program
  } do
    {:ok, _} = CNC.Program.load("square.nc", @square, server: program)
    {:ok, view, _} = live(conn, ~p"/")
    assert eventually(fn -> has_element?(view, "#bar-resume:not([disabled])") end)

    view |> element("#bar-resume") |> render_click()
    view |> element("#outline-start") |> render_click()
    refute has_element?(view, "#start-dialog")
    assert eventually(fn -> Machine.status(m).controller == :jog end)
    assert eventually(fn -> not Machine.status(m).moving? end, 10_000)
    {x, y, _} = Machine.status(m).mpos
    assert_in_delta x, 0.0, 0.01
    assert_in_delta y, 0.0, 0.01
  end

  test "Dry run: always off when the dialog opens; the lift counts in the fit; labelled while it runs",
       %{conn: conn, m: m, program: program} do
    {:ok, _} = CNC.Program.load("square.nc", @square, server: program)
    {:ok, view, _} = live(conn, ~p"/")
    assert eventually(fn -> has_element?(view, "#bar-resume:not([disabled])") end)

    # At the top of travel there's no room to lift: refused
    view |> element("#bar-resume") |> render_click()
    assert has_element?(view, "#dry-off[aria-pressed=true]")
    assert has_element?(view, "#confirm-start", "Start cutting")
    view |> element("#dry-10") |> render_click()
    assert has_element?(view, "#confirm-start[disabled]", "Start dry run")
    assert has_element?(view, "#start-checks li.is-bad")
    view |> element("#cancel-start") |> render_click()

    # Work zero 30 mm down: room to lift 10
    :ok = Machine.set_work_offset(m, z: -30.0)
    assert eventually(fn -> elem(Machine.status(m).wco, 2) == -30.0 end)
    view |> element("#bar-resume") |> render_click()
    assert has_element?(view, "#dry-off[aria-pressed=true]")
    view |> element("#dry-10") |> render_click()
    view |> element("#confirm-start") |> render_click()

    assert eventually(fn -> has_element?(view, "#machine-state", "Dry run") end)
    assert has_element?(view, "#job-mode", "Z lifted 10 mm")
    assert eventually(fn -> Machine.status(m).state == :idle end, 10_000)
    assert eventually(fn -> has_element?(view, "#note-job", "Dry run of square.nc") end)
  end

  test "Single block: chosen before Start, Next line steps, the message line says what's next",
       %{conn: conn, m: m, program: program} do
    {:ok, _} = CNC.Program.load("square.nc", @square, server: program)
    {:ok, view, _} = live(conn, ~p"/")
    assert eventually(fn -> has_element?(view, "#bar-resume:not([disabled])") end)

    view |> element("#bar-resume") |> render_click()
    assert has_element?(view, "#start-single-off[aria-pressed=true]")
    view |> element("#start-single-on") |> render_click()
    view |> element("#confirm-start") |> render_click()

    assert eventually(fn -> has_element?(view, "#note-single", "line 2 is next (G0Z0)") end)
    assert has_element?(view, "#machine-state", "Single block")
    assert has_element?(view, "#bar-resume", "Next line")
    view |> element("#bar-resume") |> render_click()
    assert eventually(fn -> has_element?(view, "#note-single", "line 3 is next") end)

    view |> element("#job-single-off") |> render_click()
    assert eventually(fn -> Machine.status(m).state == :idle end, 10_000)
    assert eventually(fn -> has_element?(view, "#note-job", "Finished square.nc") end)
  end

  test "a file picked or dropped while on another mode switches to Auto", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#panel-mdi") |> render_click()

    file =
      file_input(view, "#upload-form", :gcode, [
        %{name: "quick.nc", content: File.read!("test/fixtures/quick.nc"), type: "text/plain"}
      ])

    render_upload(file, "quick.nc")
    assert has_element?(view, "#panel-auto[aria-pressed=true]")
    assert eventually(fn -> has_element?(view, "#program-panel", "quick.nc") end)
  end

  test "a file dropped while a job runs is turned away; the job's file stays loaded", %{
    conn: conn,
    m: m,
    program: program
  } do
    {:ok, _} = CNC.Program.load("square.nc", @square, server: program)
    {:ok, view, _} = live(conn, ~p"/")
    :ok = Machine.run(m, "square.nc", @square)
    assert eventually(fn -> has_element?(view, "#job-panel", "square.nc") end)

    file =
      file_input(view, "#upload-form", :gcode, [
        %{name: "quick.nc", content: File.read!("test/fixtures/quick.nc"), type: "text/plain"}
      ])

    render_upload(file, "quick.nc")
    assert has_element?(view, "#program-panel", "A job is running")
    assert CNC.Program.current(program).name == "square.nc"
    :ok = Machine.abort(m)
  end

  test "the stock: set it; the file is checked against it before Start", %{
    conn: conn,
    program: program
  } do
    # The square is 40 x 40, 1 deep
    {:ok, _} = CNC.Program.load("square.nc", @square, server: program)
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#panel-auto") |> render_click()
    assert has_element?(view, "#stock-row", "not set")

    view |> element("#stock-edit") |> render_click()
    assert has_element?(view, "#stock-dialog #stock-zero-front_left[aria-pressed=true]")
    view |> form("#stock-form", %{width: "abc", depth: "30", thickness: "0,5"}) |> render_submit()
    assert has_element?(view, "#stock-dialog .cnc-set-error")

    view |> form("#stock-form", %{width: "30", depth: "30", thickness: "0,5"}) |> render_submit()
    refute has_element?(view, "#stock-dialog")
    assert eventually(fn -> has_element?(view, "#stock-label", "30 × 30 × 0.5 mm") end)
    assert has_element?(view, "#stock-issues", "10 mm past the stock's right edge")
    assert has_element?(view, "#stock-issues", "0.5 mm deeper than the stock is thick")

    # In the pre-start checks: a warning, Start still allowed
    view |> element("#program-start") |> render_click()
    assert has_element?(view, "#start-checks #stock-check.is-warn")
    refute has_element?(view, "#confirm-start[disabled]")
    view |> element("#cancel-start") |> render_click()

    # Big enough: on the stock
    view |> element("#stock-edit") |> render_click()
    view |> form("#stock-form", %{width: "300", depth: "200", thickness: "18"}) |> render_submit()
    assert eventually(fn -> !has_element?(view, "#stock-issues") end)
    view |> element("#program-start") |> render_click()
    assert has_element?(view, "#start-checks #stock-check.is-ok", "Stays on the stock")
    view |> element("#cancel-start") |> render_click()

    # No stock: nothing checked
    view |> element("#stock-edit") |> render_click()
    view |> element("#stock-clear") |> render_click()
    assert eventually(fn -> has_element?(view, "#stock-row", "not set") end)
  end

  test "a file that won't fit can't be started", %{conn: conn, program: program} do
    {:ok, _} = CNC.Program.load("big.nc", "G0 X0 Y0\nG1 X5000 F1000\n", server: program)
    {:ok, view, _} = live(conn, ~p"/")
    assert eventually(fn -> has_element?(view, "#bar-resume:not([disabled])") end)
    view |> element("#bar-resume") |> render_click()
    assert has_element?(view, "#start-checks li.is-bad", "Won't fit")
    assert has_element?(view, "#confirm-start[disabled]")
  end

  test "Abort asks first; the machine comes back locked; the outcome says so", %{
    conn: conn,
    m: m,
    program: program
  } do
    {:ok, _} = CNC.Program.load("square.nc", @square, server: program)
    {:ok, view, _} = live(conn, ~p"/")
    assert eventually(fn -> has_element?(view, "#bar-resume:not([disabled])") end)
    view |> element("#bar-resume") |> render_click()
    view |> element("#confirm-start") |> render_click()
    assert eventually(fn -> has_element?(view, "#job-panel") end)

    view |> element("#abort-job") |> render_click()
    assert has_element?(view, "#abort-dialog")
    view |> element("#cancel-abort") |> render_click()
    assert Machine.status(m).state == :running

    view |> element("#abort-job") |> render_click()
    view |> element("#confirm-abort") |> render_click()
    assert eventually(fn -> Machine.status(m).state == :alarm end)
    assert eventually(fn -> has_element?(view, "#note-job", "Aborted square.nc") end)
  end

  test "rapids set before Start, shown and changeable while running", %{
    conn: conn,
    m: m,
    program: program
  } do
    {:ok, _} = CNC.Program.load("square.nc", @square, server: program)
    {:ok, view, _} = live(conn, ~p"/")
    assert eventually(fn -> has_element?(view, "#bar-resume:not([disabled])") end)
    view |> element("#bar-resume") |> render_click()
    view |> element("#start-rapid-25") |> render_click()
    assert eventually(fn -> has_element?(view, "#start-rapid-25[aria-pressed=true]") end)

    view |> element("#confirm-start") |> render_click()
    assert eventually(fn -> has_element?(view, "#job-rapid-25[aria-pressed=true]") end)
    view |> element("#job-rapid-100") |> render_click()
    assert eventually(fn -> Machine.status(m).overrides == {100, 100, 100} end)
    Machine.abort(m)
  end

  test "feed override from the job panel", %{conn: conn, m: m, program: program} do
    {:ok, _} = CNC.Program.load("square.nc", @square, server: program)
    {:ok, view, _} = live(conn, ~p"/")
    assert eventually(fn -> has_element?(view, "#bar-resume:not([disabled])") end)
    view |> element("#bar-resume") |> render_click()
    view |> element("#confirm-start") |> render_click()
    assert eventually(fn -> has_element?(view, "#job-panel") end)

    view |> element("#ov-plus") |> render_click()
    assert eventually(fn -> has_element?(view, "#ov-reset", "110%") end)
    view |> element("#ov-reset") |> render_click()
    assert eventually(fn -> Machine.status(m).overrides == {100, 100, 100} end)
    Machine.abort(m)
  end

  defp eventually(fun, timeout \\ 3000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
