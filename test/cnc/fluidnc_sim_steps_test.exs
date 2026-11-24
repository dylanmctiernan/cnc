defmodule CNC.FluidNCSim.StepsTest do
  @moduledoc """
  CNC.Machine against real FluidNC firmware running natively
  (`CNC.Transport.FluidNCSim`), with this machine's `priv/fluidnc/sim.yaml`.

  Runs when FluidNC has been built (`mix cnc.fluidnc.build`); skipped otherwise
  (see test_helper.exs). Each test starts its own FluidNC in a temporary
  directory, at machine position 0,0,0.
  """
  use CNC.FluidNCSimCase, async: true

  test "steps move exactly, Z included, and Z never goes above the top", %{m: m} do
    unlock(m)
    :ok = Machine.jog_step(m, {0, 1}, 10)
    assert eventually(fn -> abs(elem(Machine.status(m).mpos, 1) - 10) < 0.001 end, 3000)

    :ok = Machine.jog_step(m, {0, 0, -1}, 10)
    assert eventually(fn -> abs(elem(Machine.status(m).mpos, 2) + 10) < 0.001 end, 3000)

    :ok = Machine.jog(m, {0, 0, 1}, :fast)
    keep_alive(m, 2000)
    :ok = Machine.jog_stop(m)
    assert eventually(fn -> Machine.status(m).controller == :idle end, 3000)
    z = elem(Machine.status(m).mpos, 2)
    assert z <= 0.0 and z > -0.01
  end

  test "work zero: set, move away, go back", %{m: m} do
    unlock(m)
    :ok = Machine.jog_step(m, {1, 1}, 20)
    assert eventually(fn -> abs(elem(Machine.status(m).mpos, 0) - 20) < 0.001 end, 3000)

    :ok = Machine.set_work_zero(m, [:x, :y])
    assert eventually(fn -> match?({+0.0, +0.0, _}, Machine.status(m).wpos) end, 3000)

    :ok = Machine.jog_step(m, {1, 1}, 10)
    assert eventually(fn -> Machine.go_to_work_zero(m) == :ok end, 8000)

    assert eventually(
             fn ->
               {x, y, _} = Machine.status(m).mpos
               abs(x - 20) < 0.002 and abs(y - 20) < 0.002
             end,
             5000
           )
  end
end
