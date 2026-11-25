defmodule CNCWeb.RunTest do
  use ExUnit.Case, async: true

  alias CNC.Machine.State
  alias CNC.Program

  # A slow 100 mm cut (10 s), then a long fast one (300 mm at 50 mm/s: 6 s),
  # then a rapid back
  @text "G0 X0 Y0\nG1 X100 F600\nG1 Y300 F3000\nG0 X0 Y0\n"

  setup do
    gcode = CNC.GCode.parse(@text, max_rate: {6000.0, 6000.0, 1200.0})
    %{program: %Program{name: "a.nc", text: @text, gcode: gcode}}
  end

  defp job(opts) do
    Map.merge(
      %{
        name: "a.nc",
        mode: :run,
        total: 4,
        acked: 0,
        recent: [],
        paused_s: 0,
        started_at: DateTime.utc_now()
      },
      Map.new(opts)
    )
  end

  defp machine(opts \\ []),
    do: struct(%State{buffer: {15, 128}, overrides: {100, 100, 100}}, opts)

  test "progress is by time: the slow first cut is most of the way", %{program: p} do
    total = p.gcode.seconds

    # Line 2 (the slow cut) done, nothing waiting in the planner
    %{fraction: f} = CNCWeb.Run.progress(job(acked: 2, recent: [2, 1]), machine(), p)
    {f2, _, x2} = Program.time_at(p, 2)
    assert_in_delta f, (f2 + x2) / total, 1.0e-9
    # (by lines, 2 of 4: 0.5)
    assert f > 0.5

    # By lines it would say 50%; acked further, but line 3 still in the
    # planner (14 blocks free: one waiting): still only line 2 done
    %{fraction: same} =
      CNCWeb.Run.progress(job(acked: 3, recent: [3, 2, 1]), machine(buffer: {14, 128}), p)

    assert same == f
  end

  test "time left: the rest at the overrides; nothing left at the end", %{program: p} do
    {f, r, x} = Program.time_total(p)
    at = job(acked: 1, recent: [1])

    %{left: left} = CNCWeb.Run.progress(at, machine(), p)
    assert left == round(f + r + x)

    %{left: slow} = CNCWeb.Run.progress(at, machine(overrides: {50, 100, 100}), p)
    assert slow == round(2 * f + r + x)

    %{left: rapids} = CNCWeb.Run.progress(at, machine(overrides: {100, 25, 100}), p)
    assert rapids == round(f + 4 * r + x)

    %{left: 0, fraction: 1.0} =
      CNCWeb.Run.progress(job(acked: 4, recent: [4, 3, 2, 1]), machine(), p)
  end

  test "once under way, scaled by the actual pace; time paused doesn't count", %{program: p} do
    {f2, _, x2} = Program.time_at(p, 2)
    done = f2 + x2
    rest = p.gcode.seconds - done
    started = DateTime.add(DateTime.utc_now(), -round(done * 2))

    # Taking twice as long as estimated: that pace, trusted as far as it's
    # got (about half way)
    %{left: left, fraction: f} =
      CNCWeb.Run.progress(job(recent: [2, 1], started_at: started), machine(), p)

    assert_in_delta left, rest * (1 + f), 1.5

    # ... unless half of that was on hold: on pace
    %{left: left, elapsed: elapsed} =
      CNCWeb.Run.progress(
        job(recent: [2, 1], started_at: started, paused_s: round(done)),
        machine(),
        p
      )

    assert_in_delta left, rest, 1.5
    assert_in_delta elapsed, done, 1.5
  end

  test "by lines, with no time left, for a check run or another file", %{program: p} do
    %{fraction: 0.5, left: nil} =
      CNCWeb.Run.progress(job(mode: :check, acked: 2, recent: [2, 1]), machine(), p)

    %{fraction: 0.5, left: nil} =
      CNCWeb.Run.progress(job(name: "b.nc", acked: 2, recent: [2, 1]), machine(), p)
  end
end
