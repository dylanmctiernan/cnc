defmodule CNC.FluidNCSim.JogTest do
  @moduledoc """
  CNC.Machine against real FluidNC firmware running natively
  (`CNC.Link.FluidNCSim`), with the sim board's config from `CNC.Boards`.

  Runs when FluidNC has been built (`mix cnc.fluidnc.build`); skipped otherwise
  (see test_helper.exs). Each test starts its own FluidNC in a temporary
  directory, at machine position 0,0,0.

  The sim is built with `priv/fluidnc/patches/sim-console-unsigned.patch`
  (stock, its console dropped bytes >= 0x80, so the jog cancel never
  reached it), so a release cancels at once here, as on the board.
  """
  use CNC.FluidNCSimCase, async: true

  test "a held jog keeps the firmware jogging without gaps, then stops", %{m: m} do
    unlock(m)
    :ok = Machine.jog(m, {1, 0}, :normal)
    assert eventually(fn -> Machine.status(m).controller == :jog end)

    samples =
      for _ <- 1..30 do
        Process.sleep(50)
        :ok = Machine.jog_heartbeat(m)
        Machine.status(m).controller
      end

    :ok = Machine.jog_stop(m)
    assert Enum.uniq(samples) == [:jog]

    assert eventually(fn -> Machine.status(m).controller == :idle end, 3000)
    {x1, _, _} = Machine.status(m).mpos
    assert x1 > 10

    # Stopped means stopped: nothing left queued.
    Process.sleep(300)
    assert elem(Machine.status(m).mpos, 0) == x1
  end

  test "a stop cancels the firmware's jog at once, not at its end", %{m: m} do
    unlock(m)
    # One 50 mm step: a single jog line, so only the cancel can cut it short
    :ok = Machine.jog_step(m, {1, 0, 0}, 50)
    assert eventually(fn -> Machine.status(m).controller == :jog end)
    Process.sleep(300)
    :ok = Machine.jog_stop(m)

    assert eventually(fn -> Machine.status(m).controller == :idle end, 5000)
    {x, _, _} = Machine.status(m).mpos
    assert x < 40, "ran on to #{x} mm: the jog cancel (0x85) didn't reach the firmware"
  end

  test "losing the heartbeat stops the firmware", %{m: m} do
    unlock(m)
    :ok = Machine.jog(m, {0, 1}, :normal)
    # no heartbeats
    assert eventually(fn -> Machine.status(m).last_error == {:jog, :heartbeat_lost} end, 600)
    assert eventually(fn -> Machine.status(m).controller == :idle end, 3000)

    # 250 ms dead-man + at most 4 increments + deceleration at 20 mm/s.
    {_, y1, _} = Machine.status(m).mpos
    assert y1 < 20
  end
end
