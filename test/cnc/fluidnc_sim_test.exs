defmodule CNC.FluidNCSimTest do
  @moduledoc """
  CNC.Machine against real FluidNC firmware running natively
  (`CNC.Transport.FluidNCSim`), with this machine's `fluidnc/sim.yaml`.

  Runs when FluidNC has been built (`mix cnc.fluidnc.build`); skipped otherwise
  (see test_helper.exs). Each test starts its own FluidNC in a temporary
  directory, at machine position 0,0,0.
  """
  use ExUnit.Case, async: true
  @moduletag :fluidnc_sim
  @moduletag :tmp_dir

  alias CNC.Machine
  alias CNC.Machine.State

  setup %{tmp_dir: dir} do
    transport =
      {CNC.Transport.FluidNCSim,
       executable: Path.expand(".fluidnc/bin/fluidnc"),
       config: Path.expand("fluidnc/sim.yaml"),
       run_dir: dir}

    topic = "fluidnc-#{System.unique_integer([:positive])}"
    spec = {Machine, name: nil, transport: transport, topic: topic}
    m = start_supervised!(Supervisor.child_spec(spec, id: make_ref()))
    assert eventually(fn -> Machine.status(m).travel_source == :controller end, 5000)
    %{m: m}
  end

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

  test "soft reset reboots the firmware and the host relocks", %{m: m} do
    unlock(m)
    :ok = Machine.reset(m)

    assert eventually(
             fn -> match?(%State{state: :alarm, alarm: :reset}, Machine.status(m)) end,
             3000
           )

    assert Enum.any?(Machine.console(m), &match?(%{dir: :in, text: "Grbl 4" <> _}, &1))
  end

  defp unlock(m) do
    :ok = Machine.unlock(m)
    assert eventually(fn -> Machine.status(m).state == :idle end)
  end

  defp keep_alive(_m, ms) when ms <= 0, do: :ok

  defp keep_alive(m, ms) do
    Machine.jog_heartbeat(m)
    Process.sleep(100)
    keep_alive(m, ms - 100)
  end

  defp eventually(fun, timeout \\ 1000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
