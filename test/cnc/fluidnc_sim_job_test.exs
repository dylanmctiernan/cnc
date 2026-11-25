defmodule CNC.FluidNCSim.JobTest do
  @moduledoc """
  Streaming a G-code file to real FluidNC firmware (`CNC.Link.FluidNCSim`):
  the stream keeps up, Hold and Resume work mid-job, it finishes Ready.
  Skipped until FluidNC is built (see test_helper.exs).
  """
  use CNC.FluidNCSimCase, async: true
  @moduletag timeout: 120_000

  # Many short moves (so the 127-byte budget is what paces the stream), an
  # arc, Z never above the top of travel.
  @program Enum.join(
             ["G21 G90", "G0 X5 Y5 Z0", "G1 Z-1 F1200"] ++
               for(i <- 1..60, do: "G1 X#{5 + rem(i, 2) * 4} Y#{5 + i * 0.5} F3000") ++
               ["G2 X5 Y45 I0 J5", "G0 Z0", "M30"],
             "\n"
           )

  test "a file streams to the end, with a Hold and Resume on the way", %{m: m} do
    unlock(m)
    :ok = Machine.run(m, "zigzag.nc", @program)
    assert eventually(fn -> Machine.status(m).controller == :run end, 3000)

    :ok = Machine.feed_hold(m)
    assert eventually(fn -> Machine.status(m).controller == :hold end, 3000)
    assert %State{state: :running} = Machine.status(m)

    :ok = Machine.resume(m)
    assert eventually(fn -> Machine.status(m).state == :idle end, 60_000)

    %State{last_job: last, mpos: {x, y, z}} = Machine.status(m)
    assert %{result: :done, acked: 66, total: 66, error: nil} = last
    assert_in_delta x, 5.0, 0.01
    assert_in_delta y, 45.0, 0.01
    assert_in_delta z, 0.0, 0.01
  end

  test "a check run: every line read, nothing moves, refused lines listed, ends locked", %{m: m} do
    unlock(m)
    program = "G21 G90\nG1 X50 Y20 F1000\nG38.2 Z-5 F100\nG2 X60 Y30 I5 J5\nG0 Z0\n"
    :ok = Machine.check(m, "check.nc", program)
    assert eventually(fn -> Machine.status(m).state == :alarm end, 10_000)
    %State{last_job: last, mpos: {x, y, _}} = Machine.status(m)
    assert %{result: :checked, total: 5, acked: 5} = last
    assert [{20, 3, "G38.2Z-5F100"}] = last.errors
    assert {x, y} == {0.0, 0.0}
  end

  test "single block steps line by line on the firmware, then runs on", %{m: m} do
    unlock(m)
    :ok = Machine.single_block(m, true)
    :ok = Machine.run(m, "steps.nc", "G21 G90\nG1 X10 F2000\nG1 Y10\nG1 X0\nG1 Y0\n")

    assert eventually(fn -> match?(%{waiting?: true, acked: 1}, Machine.status(m).job) end, 5000)
    :ok = Machine.resume(m)
    assert eventually(fn -> match?(%{waiting?: true, acked: 2}, Machine.status(m).job) end, 5000)
    {x, _, _} = Machine.status(m).mpos
    assert_in_delta x, 10.0, 0.01

    :ok = Machine.single_block(m, false)
    assert eventually(fn -> Machine.status(m).state == :idle end, 15_000)
    assert %{result: :done, acked: 5} = Machine.status(m).last_job
  end

  test "feed and rapid overrides reach the firmware mid-job, and it reports them", %{m: m} do
    unlock(m)
    # 60 mm at 10 mm/s: 6 s at 100%; a pause there (so a report sees it), a rapid back
    program = "G21 G90\nG1 X60 F600\nG4 P1\nG0 X0\n"
    t0 = System.monotonic_time(:millisecond)
    :ok = Machine.run(m, "ov.nc", program)
    assert eventually(fn -> Machine.status(m).controller == :run end, 3000)

    for _ <- 1..5, do: :ok = Machine.feed_override(m, :plus10)
    assert eventually(fn -> match?({150, _, _}, Machine.status(m).overrides) end, 3000)
    assert eventually(fn -> elem(Machine.status(m).mpos, 0) >= 59.9 end, 10_000)
    cut = System.monotonic_time(:millisecond) - t0
    # At 150% the cut is 4 s (plus the moment before the override): well
    # under the 6 s it takes at 100%
    assert cut < 5500, "the cut took #{cut} ms: the feed override didn't take"

    :ok = Machine.rapid_override(m, 25)
    assert eventually(fn -> match?({150, 25, _}, Machine.status(m).overrides) end, 3000)
    assert eventually(fn -> Machine.status(m).state == :idle end, 15_000)
    assert %{result: :done} = Machine.status(m).last_job

    :ok = Machine.feed_override(m, :reset)
    :ok = Machine.rapid_override(m, 100)
    assert eventually(fn -> match?({100, 100, _}, Machine.status(m).overrides) end, 3000)
  end
end
