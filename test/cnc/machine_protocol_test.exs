defmodule CNC.Machine.ProtocolTest do
  use CNC.MachineCase, async: true

  describe "protocol (fake controller)" do
    setup do
      topic = "machine-#{System.unique_integer([:positive])}"
      m = start_machine({CNC.ScriptedTransport, test: self()}, topic)
      assert_receive {:scripted_transport, fake, ^m}
      %{m: m, fake: fake, topic: topic}
    end

    test "speed: the path feed split into X/Y (hypotenuse) and Z", %{m: m} do
      idle(m)
      assert Machine.status(m).speed == {0.0, 0.0}

      # Diagonal in X/Y at 1200 mm/min: all of it is X/Y speed.
      send(m, {:transport, :line, "<Jog|MPos:3.000,4.000,0.000|FS:1200,0>"})
      assert {xy, z} = Machine.status(m).speed
      assert_in_delta xy, 1200, 1.0e-6
      assert_in_delta z, 0, 1.0e-6

      # Moving X and Z equally (45° down): split evenly by direction.
      send(m, {:transport, :line, "<Jog|MPos:4.000,4.000,-1.000|FS:600,0>"})
      {xy, z} = Machine.status(m).speed
      assert_in_delta xy, 600 / :math.sqrt(2), 1.0e-3
      assert_in_delta z, 600 / :math.sqrt(2), 1.0e-3

      send(m, {:transport, :line, "<Idle|MPos:4.000,4.000,-1.000|FS:0,0>"})
      assert Machine.status(m).speed == {0.0, 0.0}
    end

    test "max rates come from $110-$112, else config", %{m: m} do
      connect(m, "Alarm", {0, 0}, ["$110=2500.000", "$112=900.000"])
      assert Machine.status(m).max_rate == {2500.0, 3000.0, 900.0}
    end

    test "first status locks in :alarm, even if the controller is idle", %{m: m} do
      connect(m, "Idle", {0, 0})

      assert %State{state: :alarm, alarm: :connect, connected?: true, controller: :idle} =
               Machine.status(m)

      assert Machine.jog(m, {1, 0}, :normal) == {:error, {:invalid_state, :alarm}}
    end

    test "FluidNC is asked to report work positions ($10=2), once", %{m: m} do
      connect(m, "Alarm", {0, 0}, ["$10=1"], ["[VER:4.1 FluidNC v4.1.1:]"])
      assert_receive {:line, "$10=2"}
      ok(m)
      assert Machine.settings(m)[10] == "2"
    end

    test "already reporting work positions, or not FluidNC: $10 left alone", %{m: m} do
      connect(m, "Alarm", {0, 0}, ["$10=2"], ["[VER:4.1 FluidNC v4.1.1:]"])
      refute_receive {:line, "$10=" <> _}, 100
    end

    test "work position reports: machine position from WPos + WCO", %{m: m} do
      idle(m)

      send(
        m,
        {:transport, :line, "<Idle|WPos:-40.000,1.000,0.000|FS:0,0|WCO:48.562,0.000,0.000>"}
      )

      assert %{wpos: {-40.0, 1.0, +0.0}, mpos: {mx, 1.0, +0.0}} = Machine.status(m)
      assert_in_delta mx, 8.562, 1.0e-9

      # A later report without WCO reuses the known offset.
      send(m, {:transport, :line, "<Idle|WPos:-39.000,1.000,0.000|FS:0,0>"})
      assert_in_delta elem(Machine.status(m).mpos, 0), 9.562, 1.0e-9
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

    test "connecting mid-motion: cancel, then read settings once it's idle", %{m: m} do
      report(m, "Jog", {0, 0})
      assert_receive {:rt, 0x85}
      refute_receive {:line, "$$"}, 100
      report(m, "Idle", {1, 0})
      assert_receive {:line, "$$"}
    end

    test "settings answered with error:8 (busy) are asked for again", %{m: m} do
      report(m, "Alarm", {0, 0})
      assert_receive {:line, "$$"}
      assert_receive {:line, "$I"}
      # Busy: both are refused.
      send(m, {:transport, :line, "error:8"})
      send(m, {:transport, :line, "error:8"})
      report(m, "Alarm", {0, 0})
      assert_receive {:line, "$$"}

      for l <- ["$130=900.000", "$131=900.000", "$132=90.000", "ok"],
          do: send(m, {:transport, :line, l})

      assert Machine.status(m).travel_source == :controller
    end

    test "identifies the controller from $I and the banner", %{m: m} do
      send(m, {:transport, :line, "GrblHAL 1.1f ['$' or '$HELP' for help]"})

      connect(m, "Alarm", {0, 0}, [], [
        "[VER:1.1f.20261123:]",
        "[FIRMWARE:grblHAL]",
        "[DRIVER:Simulator]"
      ])

      assert Machine.status(m).controller_info == %{
               firmware: "grblHAL",
               version: "1.1f.20261123",
               simulated?: true
             }
    end

    test "FluidNC from its VER line; a real board isn't simulated", %{m: m} do
      connect(m, "Alarm", {0, 0}, [], ["[VER:3.9.1 FluidNC v3.9.1:]"])
      assert %{firmware: "FluidNC", simulated?: false} = Machine.status(m).controller_info
    end

    test "homing enabled comes from $22 (a bitmask in grblHAL)", %{m: m} do
      assert Machine.status(m).homing_enabled? == nil
      connect(m, "Alarm", {0, 0}, ["$22=0", "$130=500.000", "$131=500.000", "$132=50.000"])
      assert Machine.status(m).homing_enabled? == false
      :ok = Machine.send_raw(m, "$22=5")
      assert_receive {:line, "$22=5"}
      ok(m)
      assert_receive {:line, "$$"}
      for l <- ["$22=5", "ok"], do: send(m, {:transport, :line, l})
      assert Machine.status(m).homing_enabled? == true
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

    test "X+Z moves: each axis at its own tier", %{m: m} do
      idle(m)
      idle_at(m, {100, 100}, -50)
      :ok = Machine.jog(m, {1, 0, 1}, :fast)
      # X at 50 mm/s, Z at 10 mm/s: 2.5 and 0.5 mm per 50 ms tick, path F3059.
      assert_receive {:line, "$J=G91 G21 X2.500 Z0.500 F3059"}
    end

    test "analog vectors jog proportionally", %{m: m} do
      idle(m)
      idle_at(m, {100, 100}, -50)
      :ok = Machine.jog(m, {-0.25, 0.0, 0.0}, :normal)
      # a quarter of 20 mm/s: 0.25 mm per tick at F300
      assert_receive {:line, "$J=G91 G21 X-0.250 F300"}
      assert Machine.status(m).jog == {-0.25, 0.0, 0.0}

      :ok = Machine.jog(m, {0.0, 0.0, 0.0}, :normal)
      assert_receive {:rt, 0x85}, 50
      assert_raise FunctionClauseError, fn -> Machine.jog(m, {1.5, 0, 0}, :normal) end
    end

    test "a barely-deflected stick sends nothing rather than F0", %{m: m} do
      idle(m)
      idle_at(m, {100, 100}, -50)
      :ok = Machine.jog(m, {0.001, 0.0, 0.0}, :fine)
      refute_receive {:line, "$J=" <> _}, 150
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

    test "a stalled controller gets at most 4 increments + 100 ms of credit", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)

      # Controller acks everything but the position never moves: the queue is
      # bounded at 4 increments plus 100 ms (2 ticks) of report-age credit.
      assert count_jog_lines(m, 600) == 6
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

    # FluidNC ignores a jog cancel unless it's already in Jog, and runs jog
    # lines it hadn't parsed yet. A quick tap can stop before the controller
    # has even started: those lines then run after the cancel.
    test "lines that run past a stop are cancelled again", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :fast)
      assert_receive {:line, "$J=" <> _}
      :ok = Machine.jog_stop(m)
      assert_receive {:rt, @jog_cancel}

      # The controller hadn't started: the cancel was ignored. Now it parses
      # the queued lines (acks) and starts jogging: cancel again, each time.
      ok(m)
      assert_receive {:rt, @jog_cancel}, 200
      report(m, "Jog", {1, 0})
      assert_receive {:rt, @jog_cancel}, 200

      # Idle with nothing unacked: stopping is over.
      for _ <- 2..Machine.Jog.max_in_flight(), do: ok(m)
      report(m, "Idle", {2, 0})
      _ = Machine.status(m)
      flush_rt()
      report(m, "Jog", {2, 0})
      refute_receive {:rt, @jog_cancel}, 100
    end

    test "a step is not cancelled by a recent stop", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)
      :ok = Machine.jog_stop(m)
      assert_receive {:rt, @jog_cancel}
      for _ <- 1..Machine.Jog.max_in_flight(), do: ok(m)
      report(m, "Idle", {0, 0})
      _ = Machine.status(m)
      flush_rt()

      :ok = Machine.jog_step(m, {1, 0}, 10)
      assert_receive {:line, "$J=" <> _}
      ok(m)
      report(m, "Jog", {1, 0})
      refute_receive {:rt, @jog_cancel}, 100
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
      assert_receive {:scripted_transport, _new, ^m}, 500
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
end
