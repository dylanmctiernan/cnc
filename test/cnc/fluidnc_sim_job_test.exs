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
end
