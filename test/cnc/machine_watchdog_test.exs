defmodule CNC.Machine.WatchdogTest do
  use CNC.MachineCase, async: true

  describe "status watchdog" do
    setup do
      topic = "watchdog-#{System.unique_integer([:positive])}"

      spec =
        {Machine,
         name: nil,
         link: {CNC.ScriptedLink, test: self()},
         topic: topic,
         watchdog_ms: 200,
         connect_watchdog_ms: 400}

      m = start_supervised!(Supervisor.child_spec(spec, id: make_ref()))
      assert_receive {:scripted_link, fake, ^m}
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
      assert_receive {:scripted_link, _new, ^m}, 500
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

    test "connecting gets longer to see the first status", %{fake: fake} do
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
end
