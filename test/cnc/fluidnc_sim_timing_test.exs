defmodule CNC.FluidNCSim.TimingTest do
  @moduledoc """
  The time estimate (`CNC.GCode.Timing`) and progress (`CNCWeb.Run`)
  against real FluidNC firmware, timed: the estimate is close to how long
  it actually takes, progress only climbs, and time left tracks the truth.

  (The native sim's console drops bytes >= 0x80, so overrides can't be
  sent to it; their effect on the estimate is tested in isolation.)
  """
  use CNC.FluidNCSimCase, async: true
  @moduletag timeout: 120_000

  # A 50 x 30 box at F1200, a helix down at F600, rapids between; Z within
  # travel from a work zero 20 mm down
  @program """
  G21 G90 G17
  G0 Z5
  G0 X0 Y0
  G1 Z-1 F300
  G1 X50 F1200
  G1 Y30
  G1 X0
  G1 Y0
  G0 Z5
  G0 X25 Y15
  G0 X35
  G1 Z0 F300
  G2 X35 Y15 Z-1 I-10 J0 F600
  G2 X35 Y15 I-10 J0
  G0 Z5
  G0 X0 Y0
  """

  test "the estimate is close; progress climbs; time left tracks the truth", %{m: m} do
    unlock(m)
    :ok = Machine.set_work_offset(m, x: 100.0, y: 100.0, z: -20.0)

    assert eventually(
             fn -> match?(%{state: :idle, wco: {100.0, 100.0, -20.0}}, Machine.status(m)) end,
             3000
           )

    s = Machine.status(m)

    gcode =
      CNC.GCode.parse(@program,
        max_rate: s.max_rate,
        accel: s.accel,
        junction: s.junction,
        arc_tolerance: s.arc_tolerance
      )

    program = %CNC.Program{name: "t.nc", text: @program, gcode: gcode}
    t0 = System.monotonic_time(:millisecond)
    :ok = Machine.run(m, "t.nc", @program)

    samples =
      Stream.repeatedly(fn ->
        Process.sleep(500)
        st = Machine.status(m)

        if st.job,
          do:
            {System.monotonic_time(:millisecond) - t0, CNCWeb.Run.progress(st.job, st, program)},
          else: :done
      end)
      |> Enum.take_while(&(&1 != :done))

    actual = (System.monotonic_time(:millisecond) - t0) / 1000

    assert %{result: :done} = Machine.status(m).last_job

    # The file's own estimate within 15% of the real time: it can't include
    # the lead-in (from wherever the machine was to the first move, ~3 s
    # here), which time left adds once the job starts
    assert abs(actual - gcode.seconds) / actual < 0.15,
           "estimated #{gcode.seconds} s, took #{actual} s"

    fractions = for {_, p} <- samples, do: p.fraction
    assert fractions == Enum.sort(fractions), "progress went backwards: #{inspect(fractions)}"
    assert List.last(fractions) > 0.85

    # Mid-run, time left within 2 s of the truth
    for {ms, p} <- samples, ms > 3000 and ms < (actual - 3) * 1000 do
      true_left = actual - ms / 1000

      assert abs(p.left - true_left) <= 2.0,
             "at #{ms} ms: #{p.left} s left, really #{true_left}"
    end
  end
end
