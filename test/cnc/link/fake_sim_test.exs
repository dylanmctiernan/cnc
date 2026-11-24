defmodule CNC.Link.FakeSimTest do
  use ExUnit.Case, async: true

  alias CNC.Grbl.{Command, Realtime}
  alias CNC.Link.FakeSim

  setup do
    pid =
      start_supervised!(%{id: FakeSim, start: {FakeSim, :start_link, [self(), [homing_ms: 50]]}})

    assert_receive {:link, :connected}
    assert_receive {:link, :line, "Grbl" <> _}
    assert_receive {:link, :line, "[MSG:'$H'|'$X' to unlock]"}
    %{sim: pid}
  end

  test "status on request", %{sim: sim} do
    FakeSim.write_realtime(sim, Realtime.status())

    assert_receive {:link, :line,
                    "<Alarm|MPos:0.000,0.000,0.000|FS:0,0|WCO:0.000,0.000,0.000|Bf:15,128|Ov:100,100,100>"}
  end

  test "jogs move in real time and finish idle", %{sim: sim} do
    unlock(sim)
    # 1 mm at 600 mm/min ≈ 100 ms
    FakeSim.write_line(sim, Command.jog({1, 0, 0}, 600))
    assert_receive {:link, :line, "ok"}
    assert FakeSim.model(sim).state == :jog

    assert eventually(fn -> FakeSim.model(sim).state == :idle end)
    assert FakeSim.model(sim).pos == {1.0, 0.0, 0.0}
  end

  test "homing acks when the cycle completes", %{sim: sim} do
    FakeSim.write_line(sim, Command.home())
    refute_receive {:link, :line, "ok"}, 20
    assert_receive {:link, :line, "ok"}, 200
    assert FakeSim.model(sim).state == :idle
  end

  test "latency delays replies but keeps order", %{sim: sim} do
    :ok = FakeSim.configure(sim, latency: 50)
    FakeSim.write_line(sim, "$X")
    FakeSim.write_line(sim, "bogus")
    refute_receive {:link, :line, _}, 30
    assert_receive {:link, :line, "[MSG:Caution: Unlocked]"}, 100
    assert_receive {:link, :line, "ok"}
    assert_receive {:link, :line, "error:20"}
  end

  test "drop_acks swallows ok but not errors", %{sim: sim} do
    :ok = FakeSim.configure(sim, drop_acks: true)
    FakeSim.write_line(sim, "$X")
    FakeSim.write_line(sim, "bogus")
    assert_receive {:link, :line, "error:20"}
    refute_received {:link, :line, "ok"}
  end

  test "injected alarm", %{sim: sim} do
    unlock(sim)
    :ok = FakeSim.inject_alarm(sim, 1)
    assert_receive {:link, :line, "ALARM:1"}
    assert FakeSim.model(sim).state == :alarm
  end

  test "disconnect notifies the owner and exits", %{sim: sim} do
    ref = Process.monitor(sim)
    :ok = FakeSim.disconnect(sim)
    assert_receive {:link, :disconnected}
    assert_receive {:DOWN, ^ref, :process, ^sim, {:shutdown, :disconnected}}
  end

  defp unlock(sim) do
    FakeSim.write_line(sim, Command.unlock())
    assert_receive {:link, :line, "ok"}
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
