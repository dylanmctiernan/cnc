defmodule CNC.Machine.FakeSimTest do
  use CNC.MachineCase, async: true

  describe "with FakeSim" do
    setup do
      m = start_machine({CNC.Link.FakeSim, homing_ms: 50}, "sim-#{System.unique_integer()}")
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

    # Sending one increment per tick let the controller run dry between
    # increments: it flickered Jog/Idle and a real machine would stutter.
    test "a held jog keeps the controller jogging without gaps", %{m: m} do
      :ok = Machine.unlock(m)
      assert eventually(fn -> Machine.status(m).state == :idle end)
      :ok = Machine.jog(m, {1, 0}, :normal)
      assert eventually(fn -> Machine.status(m).controller == :jog end)

      samples =
        for _ <- 1..40 do
          Process.sleep(25)
          :ok = Machine.jog_heartbeat(m)
          Machine.status(m).controller
        end

      :ok = Machine.jog_stop(m)
      assert Enum.uniq(samples) == [:jog]
    end

    test "holding a key into a limit slides up to it without errors" do
      m = start_machine({CNC.Link.FakeSim, pos: {1249.0, 600.0, 0.0}}, "sim-limit")
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

    test "travel comes from the fake sim's settings" do
      sim_travel = {{0.0, 400.0}, {0.0, 300.0}, {-50.0, 0.0}}
      m = start_machine({CNC.Link.FakeSim, travel: sim_travel}, "sim-travel")
      assert eventually(fn -> Machine.status(m).travel_source == :controller end)
      assert Machine.status(m).travel == sim_travel
    end

    test "changing travel from the terminal updates the Machine", %{m: m} do
      :ok = Machine.send_raw(m, "$131=400")
      assert eventually(fn -> match?({_, {+0.0, 400.0}, _}, Machine.status(m).travel) end)
    end

    test "set work zero, move away, go back", %{m: m} do
      :ok = Machine.unlock(m)
      assert eventually(fn -> Machine.status(m).state == :idle end)
      :ok = Machine.jog_step(m, {1, 1, 0}, 10)
      assert eventually(fn -> Machine.status(m).mpos == {10.0, 10.0, 0.0} end, 3000)

      :ok = Machine.set_work_zero(m, [:x, :y])
      assert eventually(fn -> Machine.status(m).wpos == {0.0, 0.0, 0.0} end)

      :ok = Machine.jog_step(m, {1, 0, -1}, 5)
      assert eventually(fn -> Machine.status(m).wpos == {5.0, 0.0, -5.0} end, 3000)

      :ok = Machine.go_to_work_zero(m)
      # Z back near the top, X/Y at the work origin.
      assert eventually(fn -> Machine.status(m).mpos == {10.0, 10.0, -1.0} end, 3000)
    end

    test "write a setting and see it take effect", %{m: m} do
      :ok = Machine.write_settings(m, [{130, "800"}])
      assert eventually(fn -> Machine.status(m).settings_write == %{130 => :ok} end)
      assert eventually(fn -> Machine.settings(m)[130] == "800.000" end)
      assert match?({{+0.0, 800.0}, _, _}, Machine.status(m).travel)
    end

    test "disconnect and reconnect lands in :alarm", %{m: m} do
      :ok = Machine.unlock(m)
      assert eventually(fn -> Machine.status(m).state == :idle end)

      {_, data} = :sys.get_state(m)
      :ok = CNC.Link.FakeSim.disconnect(data.link)
      assert eventually(fn -> Machine.status(m).alarm == :connect end)
    end
  end
end
