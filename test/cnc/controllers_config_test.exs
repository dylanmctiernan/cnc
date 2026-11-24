defmodule CNC.Controllers.ConfigTest do
  use ExUnit.Case, async: true

  alias CNC.Controllers.Config
  alias CNC.Machine

  doctest Config
  doctest CNC.Boards

  # A machine on the fake sim, which speaks FluidNC's config-file commands.
  setup do
    id = System.unique_integer([:positive])
    m = :"config_machine_#{id}"
    spec = {Machine, name: m, topic: "config-#{id}", link: {CNC.Link.FakeSim, []}}
    start_supervised!(Supervisor.child_spec(spec, id: m))
    assert eventually(fn -> Machine.status(m).state == :alarm end, 5000)
    %{machine: m}
  end

  test "request/3 collects a multi-line reply; errors come back as codes", %{machine: m} do
    assert {:ok, ["$Config/Filename=config.yaml"]} = Machine.request(m, "$Config/Filename")
    assert {:error, 66} = Machine.request(m, "$LocalFS/Show=nope.yaml")
    # Nothing leaked into the error shown on the machine screen
    assert Machine.status(m).last_error == nil
  end

  test "list, read, save the running config as a new file, delete it", %{machine: m} do
    assert {:ok, %{files: [%{name: "config.yaml"}], active: "config.yaml"}} = Config.files(m)
    {:ok, running} = Config.running(m)
    assert running =~ "name: Fake sim"

    assert {:ok, "fast.yaml"} = Config.save_running_as(m, "fast")
    assert {:ok, %{files: names}} = Config.files(m)
    assert Enum.map(names, & &1.name) == ["config.yaml", "fast.yaml"]
    assert Config.show(m, "fast.yaml") == {:ok, running}
    assert Config.show(m, "nope.yaml") == {:error, :not_found}

    assert Config.delete(m, "config.yaml") == {:error, :active}
    assert Config.delete(m, "fast.yaml") == :ok
    assert {:ok, %{files: [_]}} = Config.files(m)
  end

  test "activate: only a file that's there; the controller restarts with it", %{machine: m} do
    assert Config.activate(m, "missing.yaml") == {:error, :not_found}
    {:ok, _} = Config.save_running_as(m, "other.yaml")

    assert :ok = Config.activate(m, "other.yaml")
    assert eventually(fn -> Machine.status(m).state == :alarm end, 3000)
    assert eventually(fn -> match?({:ok, %{active: "other.yaml"}}, Config.files(m)) end, 3000)
  end

  describe "settings" do
    setup %{tmp_dir: dir} do
      db = :"config_db_#{System.unique_integer([:positive])}"
      start_supervised!(Supervisor.child_spec({CubDB, data_dir: dir, name: db}, id: db))
      %{db: db}
    end

    @tag :tmp_dir
    test "get and set live; the read-back catches what FluidNC didn't apply", %{machine: m} do
      assert Config.get(m, "axes/x/max_rate_mm_per_min") == {:ok, "3000.000"}
      assert Config.get(m, "axes/x/nope") == {:error, :unknown_setting}
      assert {:ok, _} = Config.set(m, "axes/X/max_rate_mm_per_min", "2500")
      assert Config.get(m, "axes/x/max_rate_mm_per_min") == {:ok, "2500"}

      assert Config.set(m, "axes/x/max_rate_mm_per_min", "fast") ==
               {:error, {:not_applied, "Bad numeric value"}}

      assert Config.set(m, "stepping/engine", "RMT") ==
               {:error, {:not_applied, "Runtime setting of step_engine objects is not supported"}}

      assert Config.set(m, "axes/x/max_rate_mm_per_min", "1\n$H") == {:error, :invalid_value}
      assert Config.set(m, "../x", "1") == {:error, :invalid_setting}
      # The message FluidNC prints after error:3 doesn't confuse the next answer
      assert Config.set(m, "axes/x/nope", "1") == {:error, :unknown_setting}
      assert Config.get(m, "axes/y/steps_per_mm") == {:ok, "80.000"}
    end

    @tag :tmp_dir
    test "wiring is checked against the board's pin map" do
      board = Config.parse(CNC.Boards.config(:esp32_devkit))
      assert %{checked: n, differences: []} = Config.wiring_check(:esp32_devkit, board)
      assert n > 5

      # Same pin, attributes in another order: no difference; another pin: one
      moved =
        Enum.map(board, fn
          {"axes/x/motor0/hard_limits" = p, v} -> {p, v}
          {"axes/x/motor0/limit_neg_pin" = p, "gpio.16:low:pu"} -> {p, "GPIO.16:pu:low"}
          {"axes/y/motor0/standard_stepper/step_pin" = p, _} -> {p, "gpio.4"}
          other -> other
        end)

      assert %{differences: [%{path: "axes/y/motor0/standard_stepper/step_pin"}]} =
               Config.wiring_check(:esp32_devkit, moved)
    end

    @tag :tmp_dir
    test "history: every recorded write is a version with its reason and diff; restoring is one too",
         %{machine: m, db: db} do
      {:ok, _} = Config.upload(m, "config.yaml", "name: A\nrate: 1\n", {db, "c1", "First"})
      {:ok, _} = Config.upload(m, "config.yaml", "name: A\nrate: 2\n", {db, "c1", "Second"})

      assert [
               %{version: 2, reason: "Second", diff: [%{path: "rate", from: "1", to: "2"}]},
               %{version: 1, reason: "First", text: "name: A\nrate: 1\n"}
             ] = Config.history(db, "c1")

      [_, first] = Config.history(db, "c1")
      assert {:ok, "config.yaml"} = Config.restore(m, db, "c1", first)
      assert Config.show(m, "config.yaml") == {:ok, "name: A\nrate: 1\n"}

      assert [%{version: 3, reason: "Restored v1 (First)", diff: [%{from: "2", to: "1"}]} | _] =
               Config.history(db, "c1")

      # A live-only change: recorded without a file
      :ok = Config.record(db, "c1", %{reason: "Live", diff: [%{path: "x", from: "1", to: "2"}]})
      assert [%{version: 4, file: nil, text: nil} | _] = Config.history(db, "c1")
      assert Config.restore(m, db, "c1", hd(Config.history(db, "c1"))) == {:error, :no_file}

      assert {:ok, "six.yaml"} = Config.write_board_default(m, :six_x, "six")
      {:ok, six} = Config.show(m, "six.yaml")
      assert six =~ "engine: I2S_STREAM"
    end
  end

  defp eventually(fun, timeout) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
