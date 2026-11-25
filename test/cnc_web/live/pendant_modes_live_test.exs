defmodule CNCWeb.PendantModesLiveTest do
  @moduledoc "The pendant's modes beyond Jog: Inc, Zero (with Undo) and Job."
  use CNCWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CNC.Machine

  # A square at Z-1 (the fake sim's Z travel is -100..0), slow enough to
  # still be running while the test steers it
  @square "G21 G90\nG0 Z0\nG0 X0 Y0\nG1 Z-1 F600\nG1 X40 F600\nG1 Y40\nG1 X0\nG1 Y0\nG0 Z0\n"

  setup %{conn: conn} do
    {conn, m, program} = with_instance(conn)
    assert eventually(fn -> Machine.status(m).state == :alarm end)
    :ok = Machine.unlock(m)
    assert eventually(fn -> Machine.status(m).state == :idle and Machine.status(m).wco end)
    %{conn: conn, m: m, program: program}
  end

  test "the modes; the message line is always there", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pendant")
    assert has_element?(view, "#pendant-mode-jog[aria-pressed=true]")
    assert has_element?(view, "#pendant-msg")

    for mode <- ~w(inc zero job jog) do
      view |> element("#pendant-mode-#{mode}") |> render_click()
      assert has_element?(view, "#pendant-mode-#{mode}[aria-pressed=true]")
      assert has_element?(view, "#pendant-body.is-#{mode}")
      assert has_element?(view, "#pendant-msg")
    end
  end

  test "Inc: one press, one step on the chosen axis", %{conn: conn, m: m} do
    {:ok, view, _} = live(conn, ~p"/pendant")
    view |> element("#pendant-mode-inc") |> render_click()
    {x0, y0, _} = Machine.status(m).mpos

    view |> element("#pendant-axis-y") |> render_click()
    view |> element("#pendant-step-10") |> render_click()
    assert has_element?(view, "#pendant-step-plus", "Y+")

    view |> element("#pendant-step-plus") |> render_click()

    assert eventually(fn ->
             %{state: :idle, mpos: {x, y, _}} = Machine.status(m)
             x == x0 and abs(y - (y0 + 10)) < 0.01
           end)
  end

  test "Zero: Zero Z, then Undo puts the old zero back", %{conn: conn, m: m} do
    {:ok, view, _} = live(conn, ~p"/pendant")
    view |> element("#pendant-mode-zero") |> render_click()
    assert has_element?(view, "#pendant-undo-zero[disabled]")
    {_, _, z_before} = Machine.status(m).wco

    view |> element("#pendant-zero-z") |> render_click()
    {_, _, _, mz} = Tuple.insert_at(Machine.status(m).mpos, 0, nil)
    assert eventually(fn -> abs(elem(Machine.status(m).wco, 2) - mz) < 0.01 end)
    assert has_element?(view, "#pendant-undo-zero:not([disabled])")

    view |> element("#pendant-undo-zero") |> render_click()
    assert eventually(fn -> abs(elem(Machine.status(m).wco, 2) - z_before) < 0.01 end)
    assert has_element?(view, "#pendant-undo-zero[disabled]")
  end

  test "Inc: touch off on an edge; Zero: Trace the stock once there is one", %{conn: conn, m: m} do
    {:ok, view, _} = live(conn, ~p"/pendant")
    view |> element("#pendant-mode-inc") |> render_click()
    %{mpos: {mx, _, _}} = Machine.status(m)
    view |> element("#pendant-touch-left") |> render_click()
    assert eventually(fn -> abs(elem(Machine.status(m).wco, 0) - mx) < 0.001 end)
    assert has_element?(view, "#pendant-info", "no bit set, so taken at the tool's centre")
    assert has_element?(view, "#pendant-touch-right[disabled]")

    view |> element("#pendant-mode-zero") |> render_click()
    assert has_element?(view, "#pendant-trace-stock[disabled]")
  end

  test "Job: Start after the check; overrides, single block; Abort asks first", %{
    conn: conn,
    m: m,
    program: program
  } do
    {:ok, view, _} = live(conn, ~p"/pendant")
    view |> element("#pendant-mode-job") |> render_click()
    assert has_element?(view, "#pendant-no-file")
    assert has_element?(view, "#pendant-action[disabled]")

    {:ok, _} = CNC.Program.load("square.nc", @square, server: program)
    assert eventually(fn -> has_element?(view, "#pendant-action[data-action=start]") end)

    # The cycle button opens the same check as Start…
    view |> element("#pendant-action") |> render_click()
    assert has_element?(view, "#pendant-start-dialog li.is-ok")
    assert has_element?(view, "#pendant-stock-check", "No stock set")
    view |> element("#pendant-cancel-start") |> render_click()
    refute has_element?(view, "#pendant-start-dialog")
    assert Machine.status(m).state == :idle

    view |> element("#pendant-start") |> render_click()
    view |> element("#pendant-confirm-start") |> render_click()
    assert eventually(fn -> Machine.status(m).state == :running end)
    # The running job's panel (the file's name shows before Start too)
    assert eventually(fn -> has_element?(view, "#pendant-rapid-25") end)
    assert has_element?(view, "#pendant-job", "square.nc")

    view |> element("#pendant-rapid-25") |> render_click()
    assert eventually(fn -> match?({_, 25, _}, Machine.status(m).overrides) end)
    view |> element("#pendant-ov-plus") |> render_click()
    assert eventually(fn -> match?({110, _, _}, Machine.status(m).overrides) end)
    view |> element("#pendant-single-true") |> render_click()
    assert eventually(fn -> Machine.status(m).job.single_block? end)

    view |> element("#pendant-abort") |> render_click()
    view |> element("#pendant-cancel-abort") |> render_click()
    assert Machine.status(m).state == :running

    view |> element("#pendant-abort") |> render_click()
    view |> element("#pendant-confirm-abort") |> render_click()
    assert eventually(fn -> Machine.status(m).state == :alarm end, 4000)
    assert eventually(fn -> has_element?(view, "#pendant-action[data-action=unlock]") end)
  end

  test "a job started on the workstation shows Job on the pendant", %{
    conn: conn,
    m: m,
    program: program
  } do
    {:ok, view, _} = live(conn, ~p"/pendant")
    assert has_element?(view, "#pendant-mode-jog[aria-pressed=true]")

    {:ok, _} = CNC.Program.load("square.nc", @square, server: program)
    :ok = Machine.run(m, "square.nc", @square)
    assert eventually(fn -> has_element?(view, "#pendant-mode-job[aria-pressed=true]") end)
    assert eventually(fn -> has_element?(view, "#pendant-job", "square.nc") end)
    :ok = Machine.abort(m)
  end

  defp eventually(fun, timeout \\ 2000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
