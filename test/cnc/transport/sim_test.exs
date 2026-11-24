defmodule CNC.Transport.SimTest do
  use ExUnit.Case, async: true

  alias CNC.Grbl.{Command, Realtime}
  alias CNC.Transport.Sim

  setup do
    pid = start_supervised!(%{id: Sim, start: {Sim, :start_link, [self(), [homing_ms: 50]]}})
    assert_receive {:transport, :connected}
    assert_receive {:transport, :line, "Grbl" <> _}
    assert_receive {:transport, :line, "[MSG:'$H'|'$X' to unlock]"}
    %{sim: pid}
  end

  test "status on request", %{sim: sim} do
    Sim.write_realtime(sim, Realtime.status())
    assert_receive {:transport, :line, "<Alarm|MPos:0.000,0.000,0.000|FS:0,0|Bf:15,128>"}
  end

  test "jogs move in real time and finish idle", %{sim: sim} do
    unlock(sim)
    # 1 mm at 600 mm/min ≈ 100 ms
    Sim.write_line(sim, Command.jog({1, 0, 0}, 600))
    assert_receive {:transport, :line, "ok"}
    assert Sim.model(sim).state == :jog

    assert eventually(fn -> Sim.model(sim).state == :idle end)
    assert Sim.model(sim).pos == {1.0, 0.0, 0.0}
  end

  test "homing acks when the cycle completes", %{sim: sim} do
    Sim.write_line(sim, Command.home())
    refute_receive {:transport, :line, "ok"}, 20
    assert_receive {:transport, :line, "ok"}, 200
    assert Sim.model(sim).state == :idle
  end

  test "latency delays replies but keeps order", %{sim: sim} do
    :ok = Sim.configure(sim, latency: 50)
    Sim.write_line(sim, "$X")
    Sim.write_line(sim, "bogus")
    refute_receive {:transport, :line, _}, 30
    assert_receive {:transport, :line, "[MSG:Caution: Unlocked]"}, 100
    assert_receive {:transport, :line, "ok"}
    assert_receive {:transport, :line, "error:20"}
  end

  test "drop_acks swallows ok but not errors", %{sim: sim} do
    :ok = Sim.configure(sim, drop_acks: true)
    Sim.write_line(sim, "$X")
    Sim.write_line(sim, "bogus")
    assert_receive {:transport, :line, "error:20"}
    refute_received {:transport, :line, "ok"}
  end

  test "injected alarm", %{sim: sim} do
    unlock(sim)
    :ok = Sim.inject_alarm(sim, 1)
    assert_receive {:transport, :line, "ALARM:1"}
    assert Sim.model(sim).state == :alarm
  end

  test "disconnect notifies the owner and exits", %{sim: sim} do
    ref = Process.monitor(sim)
    :ok = Sim.disconnect(sim)
    assert_receive {:transport, :disconnected}
    assert_receive {:DOWN, ^ref, :process, ^sim, {:shutdown, :disconnected}}
  end

  defp unlock(sim) do
    Sim.write_line(sim, Command.unlock())
    assert_receive {:transport, :line, "ok"}
  end

  # Poll until fun returns true, or give up after timeout ms.
  defp eventually(fun, timeout \\ 500) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(10) && eventually(fun, timeout - 10)
    end
  end
end
