defmodule CNC.MachineTest do
  use ExUnit.Case, async: true

  alias CNC.Machine
  alias CNC.Machine.State

  @jog_cancel 0x85

  # Against CNC.FakeTransport: the test plays controller and sees every write.
  describe "protocol (fake controller)" do
    setup do
      topic = "machine-#{System.unique_integer([:positive])}"
      m = start_machine({CNC.FakeTransport, test: self()}, topic)
      assert_receive {:fake_transport, fake, ^m}
      %{m: m, fake: fake, topic: topic}
    end

    test "first status locks in :alarm, even if the controller is idle", %{m: m} do
      report(m, "Idle", {0, 0})

      assert %State{state: :alarm, alarm: :connect, connected?: true, controller: :idle} =
               Machine.status(m)

      assert Machine.jog(m, {1, 0}, :normal) == {:error, {:invalid_state, :alarm}}
    end

    test "unlock waits for the ack", %{m: m} do
      report(m, "Alarm", {0, 0})
      assert :ok = Machine.unlock(m)
      assert_receive {:line, "$X"}
      assert Machine.status(m).state == :alarm

      ok(m)
      assert %State{state: :idle, alarm: nil} = Machine.status(m)
    end

    test "jog sends increments and polls fast", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)
      # normal = 20 mm/s → 1 mm per 50 ms tick at F1200
      assert_receive {:line, "$J=G91 G21 X1.000 F1200"}
      assert_receive {:rt, ??}, 80
      assert Machine.status(m).state == :jogging
    end

    test "diagonal increments are normalised", %{m: m} do
      idle(m)
      report(m, "Idle", {100, 100})
      :ok = Machine.jog(m, {-1, 1}, :fast)
      assert_receive {:line, "$J=G91 G21 X-1.768 Y1.768 F3000"}
    end

    test "at most 4 unacked jog lines", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)

      # Controller keeps up (position follows) but never acks.
      lines =
        for k <- 1..4 do
          assert_receive {:line, "$J=" <> _ = line}
          report(m, "Jog", {k, 0})
          line
        end

      assert length(lines) == 4
      keep_alive(m, 300)
      refute_received {:line, "$J=" <> _}
    end

    test "at most 4 increments ahead of the reported position", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)

      # Controller acks everything but the position never moves.
      for _ <- 1..4 do
        assert_receive {:line, "$J=" <> _}
        ok(m)
      end

      keep_alive(m, 300)
      refute_received {:line, "$J=" <> _}
    end

    test "heartbeat loss cancels the jog within 300 ms", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)
      assert_receive {:rt, @jog_cancel}, 300

      assert %State{state: :idle, last_error: {:jog, :heartbeat_lost}, jog: {0, 0}} =
               Machine.status(m)
    end

    test "heartbeats keep the jog alive", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)
      keep_alive(m, 500)
      refute_received {:rt, @jog_cancel}
      assert Machine.status(m).state == :jogging
    end

    test "jog_stop cancels immediately", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {0, 1}, :fine)
      :ok = Machine.jog_stop(m)
      # Sent before jog_stop returns; the fake forwards it asynchronously.
      assert_receive {:rt, @jog_cancel}, 50
      assert Machine.status(m).state == :idle
    end

    test "jog to {0, 0} stops", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {0, 1}, :fine)
      :ok = Machine.jog(m, {0, 0}, :fine)
      assert_receive {:rt, @jog_cancel}, 50
    end

    test "a rejected increment ends the session", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)
      assert_receive {:line, "$J=" <> _}
      send(m, {:transport, :line, "error:15"})
      assert %State{state: :idle, last_error: {:error, 15}} = Machine.status(m)
    end

    test "ALARM:N locks from any state", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)
      send(m, {:transport, :line, "ALARM:1"})
      assert %State{state: :alarm, alarm: {:alarm, 1}, jog: {0, 0}} = Machine.status(m)
    end

    test "controller reset (banner) re-syncs and locks", %{m: m} do
      idle(m)
      send(m, {:transport, :line, "Grbl 1.1h ['$' for help]"})
      assert Machine.status(m).state == :connecting
      report(m, "Idle", {0, 0})
      assert %State{state: :alarm, alarm: :reset} = Machine.status(m)
    end

    test "door/hold reports make the machine :busy", %{m: m} do
      idle(m)
      report(m, "Door:1", {0, 0})
      assert Machine.status(m).state == :busy
      assert Machine.jog(m, {1, 0}, :normal) == {:error, {:invalid_state, :busy}}
      report(m, "Idle", {0, 0})
      assert Machine.status(m).state == :idle
    end

    test "homing goes :homing until acked", %{m: m} do
      report(m, "Alarm", {0, 0})
      :ok = Machine.home(m)
      assert_receive {:line, "$H"}
      report(m, "Home", {0, 0})
      assert Machine.status(m).state == :homing
      ok(m)
      assert Machine.status(m).state == :idle
    end

    test "transport loss disconnects, then reconnects", %{m: m, fake: fake} do
      idle(m)
      Process.exit(fake, :kill)
      assert_receive {:fake_transport, _new, ^m}, 500
      assert Machine.status(m).state == :connecting
      report(m, "Idle", {5, 5})
      assert %State{state: :alarm, alarm: :connect, mpos: {5.0, 5.0, +0.0}} = Machine.status(m)
    end

    test "broadcasts are throttled and the latest always arrives", %{m: m, topic: topic} do
      idle(m)
      Machine.subscribe(topic)
      for x <- 1..100, do: report(m, "Idle", {x, 0})

      Process.sleep(200)
      msgs = drain()
      assert length(msgs) <= 6
      assert %State{mpos: {100.0, +0.0, +0.0}} = List.last(msgs)
    end
  end

  # Against the in-process simulator, end to end.
  describe "with Sim" do
    setup do
      m = start_machine({CNC.Transport.Sim, homing_ms: 50}, "sim-#{System.unique_integer()}")
      assert eventually(fn -> Machine.status(m).state == :alarm end)
      %{m: m}
    end

    test "home, jog diagonally, stop", %{m: m} do
      :ok = Machine.home(m)
      assert eventually(fn -> Machine.status(m).state == :idle end)

      :ok = Machine.jog(m, {1, 1}, :fast)
      keep_alive(m, 300)
      :ok = Machine.jog_stop(m)

      assert eventually(fn -> Machine.status(m).controller == :idle end)
      %State{mpos: {x, y, _}} = Machine.status(m)
      assert x > 5 and x < 20
      assert_in_delta x, y, 0.01
    end

    test "holding a key into a limit slides up to it without errors" do
      m = start_machine({CNC.Transport.Sim, pos: {1249.0, 600.0, 0.0}}, "sim-limit")
      assert eventually(fn -> Machine.status(m).state == :alarm end)
      :ok = Machine.unlock(m)
      assert eventually(fn -> Machine.status(m).state == :idle end)

      # 15 mm worth of pushing at the +X edge, 1 mm away.
      :ok = Machine.jog(m, {1, 0}, :fast)
      keep_alive(m, 300)
      assert %State{state: :jogging, last_error: nil} = Machine.status(m)
      :ok = Machine.jog_stop(m)

      assert eventually(fn -> Machine.status(m).controller == :idle end)
      %State{mpos: {x, _, _}} = Machine.status(m)
      assert_in_delta x, 1249.999, 1.0e-6
      assert Machine.jog_step(m, {1, 0}, 10) == {:error, :at_limit}
    end

    test "disconnect and reconnect lands in :alarm", %{m: m} do
      :ok = Machine.unlock(m)
      assert eventually(fn -> Machine.status(m).state == :idle end)

      {_, data} = :sys.get_state(m)
      :ok = CNC.Transport.Sim.disconnect(data.transport)
      assert eventually(fn -> Machine.status(m).alarm == :connect end)
    end
  end

  ## Helpers

  defp start_machine(transport, topic) do
    spec = {Machine, name: nil, transport: transport, topic: topic}
    start_supervised!(Supervisor.child_spec(spec, id: make_ref()))
  end

  defp report(m, state, {x, y}),
    do: send(m, {:transport, :line, "<#{state}|MPos:#{x}.000,#{y}.000,0.000|FS:0,0>"})

  defp ok(m), do: send(m, {:transport, :line, "ok"})

  defp idle(m) do
    report(m, "Idle", {0, 0})
    :ok = Machine.unlock(m)
    assert_receive {:line, "$X"}
    ok(m)
    assert Machine.status(m).state == :idle
  end

  defp keep_alive(m, ms) when ms <= 0, do: Machine.status(m)

  defp keep_alive(m, ms) do
    Machine.jog_heartbeat(m)
    Process.sleep(100)
    keep_alive(m, ms - 100)
  end

  defp drain(acc \\ []) do
    receive do
      {:machine, state} -> drain([state | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp eventually(fun, timeout \\ 1000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(10) && eventually(fun, timeout - 10)
    end
  end
end
