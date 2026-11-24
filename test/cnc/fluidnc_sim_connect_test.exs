defmodule CNC.FluidNCSim.ConnectTest do
  @moduledoc """
  CNC.Machine against real FluidNC firmware running natively
  (`CNC.Link.FluidNCSim`), with this machine's `priv/fluidnc/sim.yaml`.

  Runs when FluidNC has been built (`mix cnc.fluidnc.build`); skipped otherwise
  (see test_helper.exs). Each test starts its own FluidNC in a temporary
  directory, at machine position 0,0,0.
  """
  use CNC.FluidNCSimCase, async: true

  test "connects locked as FluidNC; travel from its settings, homing off", %{m: m} do
    assert eventually(fn -> Machine.status(m).controller_info.firmware == "FluidNC" end)

    assert %State{
             state: :alarm,
             travel: {{+0.0, 1250.0}, {+0.0, 1250.0}, {-100.0, +0.0}},
             travel_issues: [],
             homing_enabled?: false,
             controller_info: %{firmware: "FluidNC", simulated?: true}
           } = Machine.status(m)

    unlock(m)
  end

  test "soft reset reboots the firmware and the host relocks", %{m: m} do
    unlock(m)
    :ok = Machine.reset(m)

    assert eventually(
             fn -> match?(%State{state: :alarm, alarm: :reset}, Machine.status(m)) end,
             3000
           )

    assert Enum.any?(Machine.console(m), &match?(%{dir: :in, text: "Grbl 4" <> _}, &1))
  end
end
