defmodule CNC.Link.UARTFluidNCTest do
  @moduledoc """
  The whole path the bench ESP32 will use, minus the board: Machine →
  CNC.Link.UART → a virtual serial port → real FluidNC (the FluidNC sim
  running as the port's terminal, via test/support/fluidnc_serial.py).

  Runs when FluidNC has been built (mix cnc.fluidnc.build).
  """
  use ExUnit.Case, async: true
  @moduletag :fluidnc_sim
  @moduletag :tmp_dir

  alias CNC.Machine
  alias CNC.Machine.State
  alias CNC.Link.FluidNCSim

  @bridge Path.expand("../../support/fluidnc_serial.py", __DIR__)

  setup %{tmp_dir: dir} do
    :ok = FluidNCSim.prepare_run_dir(dir, CNC.Boards.config(:fluidnc_sim))
    python = System.find_executable("python3") || flunk("python3 is needed for the pty bridge")

    bridge =
      Port.open({:spawn_executable, python}, [
        :binary,
        args: ["-I", @bridge, FluidNCSim.default_executable(), dir]
      ])

    assert_receive {^bridge, {:data, first}}, 3000
    [device | _] = String.split(first, "\n")
    on_exit(fn -> if Port.info(bridge), do: Port.close(bridge) end)

    spec =
      {Machine, name: nil, link: {CNC.Link.UART, port: device}, topic: "uart-#{device}"}

    m = start_supervised!(Supervisor.child_spec(spec, id: make_ref()))
    assert eventually(fn -> Machine.status(m).travel_source == :controller end, 5000)
    %{m: m}
  end

  test "connects over serial, identifies FluidNC, reads travel", %{m: m} do
    assert eventually(fn -> Machine.status(m).controller_info.firmware == "FluidNC" end)

    assert %State{
             state: :alarm,
             connected?: true,
             adapter: "UART",
             travel: {{+0.0, 1250.0}, {+0.0, 1250.0}, {-100.0, +0.0}}
           } = Machine.status(m)
  end

  test "held jog over serial runs without gaps and stops", %{m: m} do
    :ok = Machine.unlock(m)
    assert eventually(fn -> Machine.status(m).state == :idle end)
    :ok = Machine.jog(m, {1, 1}, :fast)
    assert eventually(fn -> Machine.status(m).controller == :jog end)

    samples =
      for _ <- 1..20 do
        Process.sleep(50)
        :ok = Machine.jog_heartbeat(m)
        Machine.status(m).controller
      end

    :ok = Machine.jog_stop(m)
    assert Enum.uniq(samples) == [:jog]
    assert eventually(fn -> Machine.status(m).controller == :idle end, 3000)
    {x, y, _} = Machine.status(m).mpos
    assert x > 20 and abs(x - y) < 0.01
  end

  test "a step over serial lands exactly", %{m: m} do
    :ok = Machine.unlock(m)
    assert eventually(fn -> Machine.status(m).state == :idle end)
    :ok = Machine.jog_step(m, {1, 0}, 0.1)
    assert eventually(fn -> abs(elem(Machine.status(m).mpos, 0) - 0.1) < 0.0005 end, 3000)
  end

  defp eventually(fun, timeout \\ 1000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
