defmodule CNC.Configuration.FluidNCTest do
  use ExUnit.Case, async: true

  alias CNC.Configuration
  alias CNC.Configuration.{FluidNC, History, Values}
  alias CNC.Machine

  doctest FluidNC
  doctest Values
  doctest CNC.Configuration.Build
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
    assert {:ok, %{files: [%{name: "config.yaml"}], active: "config.yaml"}} = FluidNC.files(m)
    {:ok, running} = FluidNC.running(m)
    assert running =~ "name: Fake sim"

    assert {:ok, "fast.yaml"} = FluidNC.save_running_as(m, "fast")
    assert {:ok, %{files: names}} = FluidNC.files(m)
    assert Enum.map(names, & &1.name) == ["config.yaml", "fast.yaml"]
    assert FluidNC.show(m, "fast.yaml") == {:ok, running}
    assert FluidNC.show(m, "nope.yaml") == {:error, :not_found}

    assert FluidNC.delete(m, "config.yaml") == {:error, :active}
    assert FluidNC.delete(m, "fast.yaml") == :ok
    assert {:ok, %{files: [_]}} = FluidNC.files(m)
  end

  test "activate: only a file that's there; the controller restarts with it", %{machine: m} do
    assert FluidNC.activate(m, "missing.yaml") == {:error, :not_found}
    {:ok, _} = FluidNC.save_running_as(m, "other.yaml")

    assert :ok = FluidNC.activate(m, "other.yaml")
    assert eventually(fn -> Machine.status(m).state == :alarm end, 3000)
    assert eventually(fn -> match?({:ok, %{active: "other.yaml"}}, FluidNC.files(m)) end, 3000)
  end

  test "the fake sim's config holds only what it takes" do
    paths = Enum.map(Values.parse(CNC.Boards.config(:fake_sim)), &elem(&1, 0))
    assert "name" in paths and "board" in paths
    rest = paths -- ["name", "board"]
    assert length(rest) == 6
    assert Enum.all?(rest, &(&1 =~ ~r{^axes/[xyz]/(max_rate_mm_per_min|max_travel_mm)$}))
  end

  @tag :tmp_dir
  test "the fake sim takes its travel from its config, live too, and keeps its files",
       %{tmp_dir: dir} do
    id = System.unique_integer([:positive])
    m = :"fake_takes_#{id}"
    link = {CNC.Link.FakeSim, run_dir: dir, config: CNC.Boards.config(:fake_sim)}

    start_supervised!(
      Supervisor.child_spec({Machine, name: m, topic: "ft-#{id}", link: link}, id: m)
    )

    assert eventually(fn -> Machine.status(m).state == :alarm end, 5000)

    assert eventually(
             fn -> match?({{+0.0, 1250.0}, _, {-100.0, +0.0}}, Machine.status(m).travel) end,
             3000
           )

    # Set live: the controller takes it, and the machine reads it again
    {:ok, _} = FluidNC.set(m, "axes/x/max_travel_mm", "900")
    assert eventually(fn -> match?({{+0.0, 900.0}, _, _}, Machine.status(m).travel) end, 3000)

    # Its files are kept in its folder, like flash
    {:ok, _} = FluidNC.save_running_as(m, "kept.yaml")
    assert File.read!(Path.join([dir, "localfs", "kept.yaml"])) =~ "max_travel_mm: 900"
    :ok = FluidNC.activate(m, "kept.yaml")
    assert File.read!(Path.join(dir, "config_filename")) == "kept.yaml"

    # An override with more than it takes: all of it is kept and readable;
    # what it leaves out falls back to the default
    own =
      "name: Mine\naxes:\n  x:\n    acceleration_mm_per_sec2: 333\n  y:\n    max_travel_mm: 700\n"

    # (after the restart above has settled)
    assert eventually(
             fn -> match?(%{state: :alarm, awaiting_ack: 0}, Machine.status(m)) end,
             3000
           )

    {:ok, _} = FluidNC.upload(m, "config.yaml", own)
    :ok = FluidNC.activate(m, "config.yaml")

    assert eventually(
             fn -> match?({{+0.0, 1250.0}, {+0.0, 700.0}, _}, Machine.status(m).travel) end,
             3000
           )

    assert FluidNC.get(m, "axes/x/acceleration_mm_per_sec2") == {:ok, "333"}

    model =
      CNC.Link.FakeSim.Model.new(
        files: %{"kept.yaml" => File.read!(Path.join([dir, "localfs", "kept.yaml"]))},
        config_file: "kept.yaml"
      )

    assert {{+0.0, 900.0}, _, _} = model.travel
  end

  describe "settings" do
    setup %{tmp_dir: dir} do
      db = :"config_db_#{System.unique_integer([:positive])}"
      start_supervised!(Supervisor.child_spec({CubDB, data_dir: dir, name: db}, id: db))
      %{db: db}
    end

    @tag :tmp_dir
    test "get and set live; the read-back catches what FluidNC didn't apply", %{machine: m} do
      assert FluidNC.get(m, "axes/x/max_rate_mm_per_min") == {:ok, "3000.000"}
      assert FluidNC.get(m, "axes/x/nope") == {:error, :unknown_setting}
      assert {:ok, _} = FluidNC.set(m, "axes/X/max_rate_mm_per_min", "2500")
      assert FluidNC.get(m, "axes/x/max_rate_mm_per_min") == {:ok, "2500"}

      assert FluidNC.set(m, "axes/x/max_rate_mm_per_min", "fast") ==
               {:error, {:not_applied, "Bad numeric value"}}

      assert FluidNC.set(m, "stepping/engine", "RMT") ==
               {:error, {:not_applied, "Runtime setting of step_engine objects is not supported"}}

      assert FluidNC.set(m, "axes/x/max_rate_mm_per_min", "1\n$H") == {:error, :invalid_value}
      assert FluidNC.set(m, "../x", "1") == {:error, :invalid_setting}
      # The message FluidNC prints after error:3 doesn't confuse the next answer
      assert FluidNC.set(m, "axes/x/nope", "1") == {:error, :unknown_setting}
      assert FluidNC.get(m, "axes/y/steps_per_mm") == {:ok, "80.000"}
    end

    @tag :tmp_dir
    test "wiring is checked against the board's pin map" do
      board = Values.parse(CNC.Boards.config(:esp32_devkit))
      assert %{checked: n, differences: []} = Configuration.wiring_check(:esp32_devkit, board)
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
               Configuration.wiring_check(:esp32_devkit, moved)
    end

    @tag :tmp_dir
    test "history: every recorded write is a version with its reason and diff; restoring is one too",
         %{machine: m, db: db} do
      {:ok, _} = FluidNC.upload(m, "config.yaml", "name: A\nrate: 1\n", {db, "c1", "First"})
      {:ok, _} = FluidNC.upload(m, "config.yaml", "name: A\nrate: 2\n", {db, "c1", "Second"})

      assert [
               %{version: 2, reason: "Second", diff: [%{path: "rate", from: "1", to: "2"}]},
               %{version: 1, reason: "First", text: "name: A\nrate: 1\n"}
             ] = History.list(db, "c1")

      [_, first] = History.list(db, "c1")
      assert {:ok, "config.yaml"} = History.restore(m, db, "c1", first)
      assert FluidNC.show(m, "config.yaml") == {:ok, "name: A\nrate: 1\n"}

      assert [%{version: 3, reason: "Restored v1 (First)", diff: [%{from: "2", to: "1"}]} | _] =
               History.list(db, "c1")

      # A live-only change: recorded without a file
      :ok = History.record(db, "c1", %{reason: "Live", diff: [%{path: "x", from: "1", to: "2"}]})
      assert [%{version: 4, file: nil, text: nil} | _] = History.list(db, "c1")
      assert History.restore(m, db, "c1", hd(History.list(db, "c1"))) == {:error, :no_file}

      assert {:ok, "six.yaml"} = FluidNC.write_board_default(m, :six_x, "six")
      {:ok, six} = FluidNC.show(m, "six.yaml")
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
