defmodule CNC.Machine.WorkCoordinatesTest do
  use CNC.MachineCase, async: true

  describe "work coordinates" do
    setup do
      m = start_machine({CNC.ScriptedLink, test: self()}, "work-#{System.unique_integer()}")
      assert_receive {:scripted_link, _fake, ^m}
      %{m: m}
    end

    defp at(m, {x, y, z}, wco) do
      send(m, {:link, :line, "<Idle|MPos:#{x},#{y},#{z}|FS:0,0|WCO:#{wco}>"})
      Machine.status(m)
    end

    test "set_work_zero sends G10 L20 P1 for the chosen axes", %{m: m} do
      idle(m)
      :ok = Machine.set_work_zero(m, [:x, :y])
      assert_receive {:line, "G10 L20 P1 X0.000 Y0.000"}
      :ok = Machine.set_work_zero(m, [:z])
      assert_receive {:line, "G10 L20 P1 Z0.000"}
    end

    test "set_work_position names the current position without moving", %{m: m} do
      idle(m)
      idle_at(m, {100, 100}, -20)
      # Work zero lands at machine X 87.5, Z -17: inside the travel.
      :ok = Machine.set_work_position(m, x: 12.5, z: -3)
      assert_receive {:line, "G10 L20 P1 X12.500 Z-3.000"}
      refute_received {:line, "$J=" <> _}

      # X 200 here would put the work zero at machine X -100: off the machine.
      assert Machine.set_work_position(m, x: 200) == {:error, :outside_travel}
      refute_received {:line, "G10" <> _}

      assert Machine.set_work_position(m, x: 200_000) == {:error, :invalid_value}
      assert Machine.set_work_position(m, a: 1) == {:error, :invalid_value}
      assert Machine.set_work_position(m, x: "1") == {:error, :invalid_value}
    end

    test "set_work_offset puts the zero at machine coordinates (G10 L2)", %{m: m} do
      idle(m)
      :ok = Machine.set_work_offset(m, x: 300, z: -42.5)
      assert_receive {:line, "G10 L2 P1 X300.000 Z-42.500"}
      assert Machine.set_work_offset(m, x: 2000) == {:error, :outside_travel}
      assert Machine.set_work_offset(m, z: 5) == {:error, :outside_travel}
      refute_received {:line, "G10" <> _}
    end

    test "set_work_zero is refused unless idle", %{m: m} do
      connect(m, "Alarm", {0, 0})
      assert Machine.set_work_zero(m, [:x]) == {:error, {:invalid_state, :alarm}}
    end

    test "go to work zero: lift Z near the top first, then X/Y", %{m: m} do
      idle(m)
      at(m, {100, 100, -50}, "10,20,-30")
      :ok = Machine.go_to_work_zero(m)
      assert_receive {:line, "$J=G91 G21 Z49.000 F600"}
      assert_receive {:line, "$J=G91 G21 X-90.000 Y-80.000 F3000"}
    end

    test "go to work zero never lowers Z", %{m: m} do
      idle(m)
      at(m, {100, 100, -0.5}, "10,20,-30")
      :ok = Machine.go_to_work_zero(m)
      assert_receive {:line, "$J=G91 G21 X-90.000 Y-80.000 F3000"}
      refute_receive {:line, "$J=G91 G21 Z" <> _}, 100
    end

    test "a work zero at the machine origin is reachable", %{m: m} do
      idle(m)
      at(m, {100, 100, 0}, "0,0,0")
      :ok = Machine.go_to_work_zero(m)
      assert_receive {:line, "$J=G91 G21 X-99.999 Y-99.999 F3000"}
    end

    test "refuses while a move may still be running", %{m: m} do
      idle(m)
      at(m, {100, 100, 0}, "10,20,0")
      :ok = Machine.jog_step(m, {1, 0, 0}, 10)
      assert_receive {:line, "$J=" <> _}
      # Not acked yet; then acked but no report since: both unsettled.
      assert Machine.go_to_work_zero(m) == {:error, :moving}
      ok(m)
      assert Machine.go_to_work_zero(m) == {:error, :moving}
      # The controller reports it's jogging: still no.
      send(m, {:link, :line, "<Jog|MPos:105,100,0|FS:1200,0>"})
      assert Machine.go_to_work_zero(m) == {:error, :moving}
      assert Machine.status(m).moving?
      # Stopped: fine.
      send(m, {:link, :line, "<Idle|MPos:110,100,0|FS:0,0>"})
      refute Machine.status(m).moving?
      assert :ok = Machine.go_to_work_zero(m)
      assert_receive {:line, "$J=G91 G21 X-100.000 Y-80.000 F3000"}
    end

    test "refuses when the work zero is outside travel or unknown", %{m: m} do
      idle(m)
      assert Machine.go_to_work_zero(m) == {:error, :no_work_offset}
      at(m, {100, 100, 0}, "-50,0,0")
      assert Machine.go_to_work_zero(m) == {:error, :outside_travel}
      refute_receive {:line, "$J=" <> _}, 100
    end
  end
end
