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
      connect(m, "Idle", {0, 0})

      assert %State{state: :alarm, alarm: :connect, connected?: true, controller: :idle} =
               Machine.status(m)

      assert Machine.jog(m, {1, 0}, :normal) == {:error, {:invalid_state, :alarm}}
    end

    test "reads travel from the controller's $130-$132", %{m: m} do
      assert Machine.status(m).travel_source == :config
      connect(m, "Alarm", {0, 0}, ["$0=10", "$130=500.000", "$131=300.000", "$132=80.000"])

      assert %State{
               travel: {{+0.0, 500.0}, {+0.0, 300.0}, {-80.0, +0.0}},
               travel_source: :controller
             } =
               Machine.status(m)
    end

    test "controller may narrow travel but never widen it", %{m: m} do
      connect(m, "Alarm", {0, 0}, ["$130=12500.000", "$131=300.000", "$132=80.000"])

      assert %State{
               travel: {{+0.0, 1250.0}, {+0.0, 300.0}, {-80.0, +0.0}},
               travel_issues: [{:x, 12500.0, 1250.0}]
             } = Machine.status(m)
    end

    test "keeps configured travel if the controller's is incomplete", %{m: m} do
      connect(m, "Alarm", {0, 0}, ["$130=500.000", "$131=0"])
      assert %State{travel_source: :config, travel: {{+0.0, 1250.0}, _, _}} = Machine.status(m)
    end

    test "unlock waits for the ack", %{m: m} do
      connect(m, "Alarm", {0, 0})
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

    test "Z jogs at the Z tier speed", %{m: m} do
      idle(m)
      idle_at(m, {100, 100}, -50)
      :ok = Machine.jog(m, {0, 0, -1}, :normal)
      # normal Z = 5 mm/s → 0.25 mm per 50 ms tick at F300
      assert_receive {:line, "$J=G91 G21 Z-0.250 F300"}
    end

    test "X+Z moves keep Z within its tier", %{m: m} do
      idle(m)
      idle_at(m, {100, 100}, -50)
      :ok = Machine.jog(m, {1, 0, 1}, :fast)
      # 45° in XZ: Z capped at 10 mm/s → path 14.14 mm/s (F849), so each axis
      # moves 0.5 mm per 50 ms tick: Z at exactly its 10 mm/s.
      assert_receive {:line, "$J=G91 G21 X0.500 Z0.500 F849"}
    end

    test "Z can't jog above the top of travel", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {0, 0, 1}, :normal)
      refute_receive {:line, "$J=" <> _}, 200
      :ok = Machine.jog_stop(m)
      assert Machine.jog_step(m, {0, 0, 1}, 1) == {:error, :at_limit}
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

      assert %State{state: :idle, last_error: {:jog, :heartbeat_lost}, jog: {0, 0, 0}} =
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
      assert %State{state: :alarm, alarm: {:alarm, 1}, jog: {0, 0, 0}} = Machine.status(m)
    end

    test "controller reset (banner) re-syncs and locks", %{m: m} do
      idle(m)
      send(m, {:transport, :line, "Grbl 1.1h ['$' for help]"})
      assert Machine.status(m).state == :connecting
      connect(m, "Idle", {0, 0})
      assert %State{state: :alarm, alarm: :reset} = Machine.status(m)
    end

    test "the work offset carries over reports that omit it", %{m: m} do
      idle(m)
      send(m, {:transport, :line, "<Idle|MPos:10.000,20.000,0.000|FS:0,0|WCO:1.000,2.000,0.000>"})
      report(m, "Idle", {11, 20})

      assert %State{wco: {1.0, 2.0, +0.0}, wpos: {10.0, 18.0, +0.0}, mpos: {11.0, 20.0, +0.0}} =
               Machine.status(m)
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
      connect(m, "Alarm", {0, 0})
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
      connect(m, "Idle", {5, 5})
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

  describe "status watchdog" do
    setup do
      topic = "watchdog-#{System.unique_integer([:positive])}"

      spec =
        {Machine,
         name: nil,
         transport: {CNC.FakeTransport, test: self()},
         topic: topic,
         watchdog_ms: 200,
         connect_watchdog_ms: 400}

      m = start_supervised!(Supervisor.child_spec(spec, id: make_ref()))
      assert_receive {:fake_transport, fake, ^m}
      %{m: m, fake: fake}
    end

    test "a silent controller mid-jog: jog cancel, link dropped, reconnect", %{m: m, fake: fake} do
      ref = Process.monitor(fake)
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)
      # Heartbeats keep coming, but the controller never reports again.
      Machine.jog_heartbeat(m)
      Process.sleep(100)
      Machine.jog_heartbeat(m)

      assert_receive {:rt, 0x85}, 300
      assert_receive {:DOWN, ^ref, :process, ^fake, {:shutdown, _}}
      assert_receive {:fake_transport, _new, ^m}, 500
      assert %State{state: :connecting, last_error: {:link, :no_response}} = Machine.status(m)
    end

    test "status reports keep it alive", %{m: m, fake: fake} do
      idle(m)

      for _ <- 1..6 do
        Process.sleep(100)
        report(m, "Idle", {0, 0})
      end

      assert Process.alive?(fake)
      assert Machine.status(m).state == :idle
    end

    test "connecting gets longer to see the first status", %{m: m, fake: fake} do
      Process.sleep(300)
      assert Process.alive?(fake)
      ref = Process.monitor(fake)
      assert_receive {:DOWN, ^ref, :process, ^fake, {:shutdown, _}}, 300
    end

    test "homing is exempt: grblHAL goes quiet while homing", %{m: m, fake: fake} do
      connect(m, "Alarm", {0, 0})
      :ok = Machine.home(m)
      Process.sleep(500)
      assert Process.alive?(fake)
      assert Machine.status(m).state == :homing
    end
  end

  describe "console" do
    setup do
      topic = "console-#{System.unique_integer([:positive])}"
      m = start_machine({CNC.FakeTransport, test: self()}, topic)
      assert_receive {:fake_transport, _fake, ^m}
      Machine.subscribe_console(topic)
      %{m: m, topic: topic}
    end

    test "logs traffic both ways, with real-time bytes named", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)
      :ok = Machine.jog_stop(m)

      texts = for e <- Machine.console(m), do: {e.dir, e.text}
      assert {:out, "$X"} in texts
      assert {:in, "ok"} in texts
      assert {:out, "$J=G91 G21 X1.000 F1200"} in texts
      assert {:out, "0x85 jog cancel"} in texts
      assert_received {:machine_console, %{dir: :out, text: "$X"}}
    end

    test "status polls stream on their own topic and stay out of history", %{m: m, topic: topic} do
      connect(m, "Idle", {0, 0})
      refute_receive {:machine_console, %{kind: :poll}}, 250

      Machine.subscribe_polls(topic)
      assert_receive {:machine_console, %{kind: :poll, dir: :out, text: "? status"}}, 300
      report(m, "Idle", {1, 0})
      assert_receive {:machine_console, %{kind: :poll, dir: :in, text: "<Idle|" <> _}}

      refute Enum.any?(Machine.console(m), &(&1.kind == :poll))
    end

    test "history keeps the newest 200" do
      console =
        Enum.reduce(1..250, CNC.Machine.Console.new(), fn i, c ->
          CNC.Machine.Console.push(c, CNC.Machine.Console.entry(:out, :line, "L#{i}"))
        end)

      list = CNC.Machine.Console.to_list(console)
      assert length(list) == 200
      assert {hd(list).text, List.last(list).text} == {"L51", "L250"}
    end
  end

  describe "terminal (send_raw)" do
    setup do
      m = start_machine({CNC.FakeTransport, test: self()}, "raw-#{System.unique_integer()}")
      assert_receive {:fake_transport, _fake, ^m}
      %{m: m}
    end

    test "passes lines through and tracks their acks", %{m: m} do
      idle(m)
      assert :ok = Machine.send_raw(m, "  $G  ")
      assert_receive {:line, "$G"}
      assert Machine.status(m).awaiting_ack == 1
      send(m, {:transport, :line, "error:20"})
      assert %State{awaiting_ack: 0, last_error: {:error, 20}} = Machine.status(m)
    end

    test "$x unlocks through the normal path", %{m: m} do
      connect(m, "Alarm", {0, 0})
      assert :ok = Machine.send_raw(m, "$x")
      assert_receive {:line, "$X"}
      ok(m)
      assert Machine.status(m).state == :idle
    end

    test "a setting write re-reads settings, so travel follows", %{m: m} do
      idle(m)
      :ok = Machine.send_raw(m, "$130=500")
      assert_receive {:line, "$130=500"}
      ok(m)
      assert_receive {:line, "$$"}

      for l <- ["$130=500.000", "$131=1250.000", "$132=100.000", "ok"],
          do: send(m, {:transport, :line, l})

      assert %State{travel: {{+0.0, 500.0}, _, _}, travel_source: :controller} = Machine.status(m)
    end

    test "?, ! and ~ go out as real-time bytes, not lines", %{m: m} do
      idle(m)

      for {typed, byte} <- [{"?", ??}, {"!", ?!}, {"~", ?~}] do
        assert :ok = Machine.send_raw(m, typed)
        assert_receive {:rt, ^byte}
      end

      refute_received {:line, _}
      assert Machine.status(m).awaiting_ack == 0
    end

    test "refused while jogging, and for blank or multi-line input", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)
      assert Machine.send_raw(m, "$$") == {:error, {:invalid_state, :jogging}}
      assert Machine.send_raw(m, "   ") == {:error, :invalid_line}
      assert Machine.send_raw(m, "G0 X1\nG0 X2") == {:error, :invalid_line}
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

    test "travel comes from the Sim's settings" do
      sim_travel = {{0.0, 400.0}, {0.0, 300.0}, {-50.0, 0.0}}
      m = start_machine({CNC.Transport.Sim, travel: sim_travel}, "sim-travel")
      assert eventually(fn -> Machine.status(m).travel_source == :controller end)
      assert Machine.status(m).travel == sim_travel
    end

    test "changing travel from the terminal updates the Machine", %{m: m} do
      :ok = Machine.send_raw(m, "$131=400")
      assert eventually(fn -> match?({_, {+0.0, 400.0}, _}, Machine.status(m).travel) end)
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

  # First status after (re)connect: Machine then asks for settings ($$).
  # Play the controller: send the given setting lines, then ok.
  defp connect(m, state, pos, settings \\ []) do
    report(m, state, pos)
    assert_receive {:line, "$$"}
    for line <- settings, do: send(m, {:transport, :line, line})
    ok(m)
  end

  defp idle(m) do
    connect(m, "Idle", {0, 0})
    :ok = Machine.unlock(m)
    assert_receive {:line, "$X"}
    ok(m)
    assert Machine.status(m).state == :idle
  end

  # Already idle (unlocked); report a new position including Z.
  defp idle_at(m, {x, y}, z) do
    send(m, {:transport, :line, "<Idle|MPos:#{x}.000,#{y}.000,#{z}.000|FS:0,0>"})
    Machine.status(m)
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
