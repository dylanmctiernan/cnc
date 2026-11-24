defmodule CNC.ConfigurationTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias CNC.Configuration
  alias CNC.Configuration.{FluidNC, History, Profiles, Values, Wiring, Yaml}
  alias CNC.Controllers.Controller
  alias CNC.Machine

  doctest Yaml

  test "yaml: set by path (any case, adding what's missing) and write back out" do
    tree = Yaml.parse("name: R\naxes:\n  X:\n    steps_per_mm: 80\n")
    tree = tree |> Yaml.put("axes/x/steps_per_mm", "100") |> Yaml.put("axes/x/homing/cycle", "2")
    tree = Yaml.put(tree, "start/must_home", "false")

    assert Yaml.render(tree) ==
             "name: R\naxes:\n  X:\n    steps_per_mm: 100\n    homing:\n      cycle: 2\nstart:\n  must_home: false\n"

    assert Yaml.parse(Yaml.render(tree)) == tree

    # Filtering keeps what's asked for, and empty maps that were empty
    t = Yaml.parse("a: 1\nk:\n  C:\nx:\n  y: 2\n  z: 3\n")
    assert Yaml.render(Yaml.filter(t, &(&1 == "x/z"))) == "k:\n  C:\nx:\n  z: 3\n"
    # Every board's config survives a round trip
    for board <- CNC.Boards.ids() do
      text = CNC.Boards.config(board)
      assert Values.parse(Yaml.render(Yaml.parse(text))) == Values.parse(text)
    end
  end

  test "a controller's file: its wiring, the build and the profile, nothing merged in", %{
    db: db
  } do
    esp = %{id: "esp", board: :esp32_devkit}
    Wiring.ensure(db, esp.id, CNC.Boards.config(:esp32_devkit))

    profile = %{
      id: "p",
      name: "Tiny",
      values: %{"axes/x/max_rate_mm_per_min" => "2000"},
      history: []
    }

    text = Configuration.render(db, esp, profile)
    values = Map.new(Values.parse(text))

    assert values["axes/x/max_rate_mm_per_min"] == "2000"
    # Wiring from the controller's record
    assert values["axes/x/motor0/standard_stepper/step_pin"] == "gpio.25"
    assert values["stepping/engine"] == "RMT"
    # The build (here, from the fake sim seen in setup)
    assert values["axes/x/max_travel_mm"] == "1250.000"
    # The board's other defaults aren't filled in
    refute Map.has_key?(values, "axes/y/max_rate_mm_per_min")
    refute Map.has_key?(values, "axes/x/acceleration_mm_per_sec2")
  end

  # A machine on the fake sim and a database, per test.
  setup %{tmp_dir: dir} do
    id = System.unique_integer([:positive])
    m = :"profiles_machine_#{id}"
    spec = {Machine, name: m, topic: "profiles-#{id}", link: {CNC.Link.FakeSim, []}}
    start_supervised!(Supervisor.child_spec(spec, id: m))
    db = :"profiles_db_#{id}"
    start_supervised!(Supervisor.child_spec({CubDB, data_dir: dir, name: db}, id: db))
    assert eventually(fn -> Machine.status(m).state == :alarm end)
    ctl = %Controller{id: "c1", name: "Fake", board: :fake_sim, link: %{type: :fake_sim}}
    :ok = Configuration.ensure(m, db, ctl)
    %{m: m, db: db, ctl: ctl}
  end

  test "first contact: Default from what it runs, selected; its file matches", %{
    m: m,
    db: db,
    ctl: ctl
  } do
    assert [%{name: "Default", values: values}] = Profiles.list(db)
    assert values["axes/x/max_rate_mm_per_min"] == "3000.000"
    refute Map.has_key?(values, "stepping/engine")
    assert %{name: "Default"} = Profiles.selected(db)

    # Its file holds what the profile would write: it matches, though the
    # app didn't write it
    assert {:ok, %{matches?: true, loaded: "config.yaml", written_by_app?: false}} =
             Configuration.check(m, db, ctl)

    assert Configuration.last_seen(db, "c1") == %{name: "Default", matches?: true}
  end

  test "a change goes to its part: profile and build live, wiring after a restart", %{
    m: m,
    db: db,
    ctl: ctl
  } do
    assert {:ok, %{applied: applied, errors: errors, restart?: false}} =
             Configuration.set(m, db, ctl, [
               {"axes/x/max_rate_mm_per_min", "2500"},
               {"axes/x/steps_per_mm", "100"},
               {"axes/y/acceleration_mm_per_sec2", "fast"}
             ])

    assert Map.keys(applied) == ["axes/x/max_rate_mm_per_min", "axes/x/steps_per_mm"]
    assert %{"axes/y/acceleration_mm_per_sec2" => {:not_applied, _}} = errors

    # Each in its part, and live
    assert FluidNC.get(m, "axes/x/max_rate_mm_per_min") == {:ok, "2500"}
    assert [%{values: %{"axes/x/max_rate_mm_per_min" => "2500"} = values}] = Profiles.list(db)
    refute Map.has_key?(values, "axes/x/steps_per_mm")
    assert CNC.Configuration.Build.values(db)["axes/x/steps_per_mm"] == "100"

    {:ok, file} = FluidNC.show(m, "config.yaml")
    assert file =~ ~s(profile "Default")
    assert file =~ "max_rate_mm_per_min: 2500"
    assert file =~ "steps_per_mm: 100"
    assert {:ok, %{matches?: true, written_by_app?: true}} = Configuration.check(m, db, ctl)

    assert [%{file: "config.yaml", reason: "Changed 2 values (the build, profile Default)"}] =
             History.list(db, "c1")

    assert Configuration.drift(m, db, ctl) == {:ok, []}

    # Wiring: the controller's, written, and the controller restarts with it
    assert {:ok, %{restart?: true}} = Configuration.set(m, db, ctl, [{"stepping/engine", "RMT"}])
    assert Wiring.values(db, "c1")["stepping/engine"] == "RMT"
    assert eventually(fn -> FluidNC.get(m, "stepping/engine") == {:ok, "RMT"} end)
    assert eventually(fn -> match?({:ok, %{matches?: true}}, Configuration.check(m, db, ctl)) end)
  end

  test "switching writes the one file and restarts; the other profile's values come back", %{
    m: m,
    db: db,
    ctl: ctl
  } do
    [default] = Profiles.list(db)
    {:ok, fast} = Profiles.create(db, "Fast accel", :fake_sim, default.id)
    assert Profiles.create(db, "fast ACCEL", :fake_sim, default.id) == {:error, :exists}
    {:ok, board} = Profiles.create(db, "Board", :fake_sim, :board)
    assert board.values["axes/x/max_rate_mm_per_min"]

    assert Profiles.diff(default, fast) == []
    {:ok, _} = Profiles.edit(db, fast.id, [{"axes/x/acceleration_mm_per_sec2", "800"}])
    fast = Enum.find(Profiles.list(db), &(&1.id == fast.id))

    assert [%{path: "axes/x/acceleration_mm_per_sec2", to: "800"}] =
             Profiles.diff(default, fast)

    :ok = Configuration.switch(m, db, ctl, fast.id)
    assert eventually(fn -> Machine.status(m).state == :alarm end)
    assert eventually(fn -> match?({:ok, %{matches?: true}}, Configuration.check(m, db, ctl)) end)
    assert %{name: "Fast accel"} = Profiles.selected(db)
    {:ok, _} = Configuration.set(m, db, ctl, [{"axes/x/acceleration_mm_per_sec2", "900"}])

    :ok = Configuration.switch(m, db, ctl, default.id)

    assert eventually(fn ->
             match?(
               {:ok, %{profile: %{name: "Default"}, matches?: true}},
               Configuration.check(m, db, ctl)
             )
           end)

    {:ok, accel} = FluidNC.get(m, "axes/x/acceleration_mm_per_sec2")
    assert Values.same?(accel, "500")
    # Still one file on the controller
    assert {:ok, %{files: [%{name: "config.yaml"}]}} = FluidNC.files(m)

    assert Profiles.delete(db, default.id) == {:error, :in_use}
    assert Profiles.rename(db, fast.id, "Default") == {:error, :exists}
    :ok = Profiles.rename(db, fast.id, "Quick")
    :ok = Profiles.delete(db, board.id)
    assert Enum.map(Profiles.list(db), & &1.name) == ["Default", "Quick"]
  end

  test "the file differs (an earlier version restored): write the profile, or keep the file", %{
    m: m,
    db: db,
    ctl: ctl
  } do
    {:ok, _} = Configuration.set(m, db, ctl, [{"axes/x/max_rate_mm_per_min", "2500"}])
    {:ok, _} = Configuration.set(m, db, ctl, [{"axes/x/max_rate_mm_per_min", "2600"}])

    assert [%{version: 2, reason: "Changed 1 value (profile Default)"}, %{version: 1} = v1] =
             History.list(db, "c1")

    {:ok, _} = History.restore(m, db, "c1", v1)
    # (The page restarts the controller after restoring its file.)
    :ok = FluidNC.activate(m, "config.yaml")
    assert eventually(fn -> Machine.status(m).state == :alarm end)

    {:ok, %{matches?: false, differences: diffs}} = Configuration.check(m, db, ctl)

    assert %{profile: "2600", controller: "2500"} =
             Enum.find(diffs, &(&1.path == "axes/x/max_rate_mm_per_min"))

    # The file's values win: they go into the profile, which is written
    :ok = Configuration.take_file(m, db, ctl)
    assert eventually(fn -> match?({:ok, %{matches?: true}}, Configuration.check(m, db, ctl)) end)
    assert [%{values: %{"axes/x/max_rate_mm_per_min" => "2500"}}] = Profiles.list(db)

    assert %{reason: "Kept the controller's values (profile Default)"} =
             hd(History.list(db, "c1"))
  end

  test "a profile's history: a version per change; restoring is a new version", %{
    m: m,
    db: db,
    ctl: ctl
  } do
    [default] = Profiles.list(db)
    {:ok, fast} = Profiles.create(db, "Fast", :fake_sim, default.id)
    {:ok, _} = Profiles.edit(db, fast.id, [{"axes/x/acceleration_mm_per_sec2", "800"}])
    :ok = Profiles.rename(db, fast.id, "Quick")

    quick = Enum.find(Profiles.list(db), &(&1.id == fast.id))

    assert [
             %{version: 3, reason: "Renamed from Fast", diff: []},
             %{version: 2, reason: "Edited", diff: [%{path: "axes/x/acceleration_mm_per_sec2"}]},
             %{version: 1, reason: "Made as a copy of Default"}
           ] = quick.history

    assert [%{path: "axes/x/acceleration_mm_per_sec2", from: "800"}] =
             Profiles.restore_diff(db, fast.id, 2)

    :ok = Configuration.restore_profile(m, db, ctl, fast.id, 2)
    quick = Enum.find(Profiles.list(db), &(&1.id == fast.id))
    assert %{version: 4, reason: "Restored v1"} = hd(quick.history)
    assert quick.values["axes/x/acceleration_mm_per_sec2"] == "500.000"
    # Not the selected profile: nothing went to the controller
    assert History.list(db, "c1") == []

    # The selected one: written, and recorded on the controller's side too
    {:ok, _} = Configuration.set(m, db, ctl, [{"axes/x/max_rate_mm_per_min", "2500"}])
    :ok = Configuration.restore_profile(m, db, ctl, default.id, 1)
    assert eventually(fn -> match?({:ok, %{matches?: true}}, Configuration.check(m, db, ctl)) end)
    assert %{reason: "Restored profile Default to its v1"} = hd(History.list(db, "c1"))
  end

  test "drift: a console change shows; keep it or put it back", %{m: m, db: db, ctl: ctl} do
    {:ok, _} = Machine.request(m, "$/axes/z/max_rate_mm_per_min=800")

    assert {:ok, [%{path: "axes/z/max_rate_mm_per_min", controller: "800"}]} =
             Configuration.drift(m, db, ctl)

    :ok = Configuration.put_back(m, db, ctl)
    assert Configuration.drift(m, db, ctl) == {:ok, []}

    {:ok, _} = Machine.request(m, "$/axes/z/max_rate_mm_per_min=700")
    :ok = Configuration.keep_drift(m, db, ctl)
    assert Configuration.drift(m, db, ctl) == {:ok, []}
    assert [%{values: %{"axes/z/max_rate_mm_per_min" => "700"}}] = Profiles.list(db)
  end

  test "another file loaded is an override; uploading your own replaces config.yaml", %{
    m: m,
    db: db,
    ctl: ctl
  } do
    {:ok, _} = FluidNC.save_running_as(m, "mine.yaml")
    :ok = FluidNC.activate(m, "mine.yaml")

    assert eventually(fn ->
             match?(
               {:ok, %{override?: true, loaded: "mine.yaml"}},
               Configuration.check(m, db, ctl)
             )
           end)

    assert Configuration.set(m, db, ctl, [{"axes/x/max_rate_mm_per_min", "1"}]) ==
             {:error, :override}

    assert %{matches?: false} = Configuration.last_seen(db, "c1")

    # The escape hatch: a file of your own becomes config.yaml
    {:ok, text} = FluidNC.show(m, "mine.yaml")
    own = String.replace(text, "max_rate_mm_per_min: 3000.000", "max_rate_mm_per_min: 1500")
    assert Configuration.replace_file(m, db, ctl, "", "Pasted") == {:error, :not_a_config}
    :ok = Configuration.replace_file(m, db, ctl, own, "Uploaded own.yaml")

    assert eventually(fn ->
             match?(
               {:ok, %{loaded: "config.yaml", matches?: false, written_by_app?: false}},
               Configuration.check(m, db, ctl)
             )
           end)

    {:ok, %{differences: diffs}} = Configuration.check(m, db, ctl)
    assert Enum.any?(diffs, &(&1.controller == "1500"))

    # A file that leaves settings out differs by those too
    :ok =
      Configuration.replace_file(
        m,
        db,
        ctl,
        "name: Mine\naxes:\n  x:\n    max_rate_mm_per_min: 3000\n",
        "Pasted a config"
      )

    assert %{reason: "Pasted a config"} = hd(History.list(db, "c1"))

    assert eventually(fn ->
             match?({:ok, %{written_by_app?: false}}, Configuration.check(m, db, ctl))
           end)

    {:ok, %{differences: diffs}} = Configuration.check(m, db, ctl)
    assert Enum.any?(diffs, &(&1.path == "axes/y/max_rate_mm_per_min" and &1.controller == nil))
  end

  describe "the staged changeset" do
    test "staging replaces a staged value; staging it back drops it", %{db: db} do
      alias CNC.Configuration.Changes
      c = %{part: :build, target: nil, path: "axes/x/steps_per_mm", from: "80.000", to: "100"}
      :ok = Changes.stage(db, [c])
      :ok = Changes.stage(db, [%{c | from: "100", to: "120"}])
      assert [%{from: "80.000", to: "120"}] = Changes.list(db)
      :ok = Changes.stage(db, [%{c | from: "120", to: "80"}])
      assert Changes.list(db) == []
    end

    test "applied together: the running parts live in one write, another profile stored", %{
      m: m,
      db: db,
      ctl: ctl
    } do
      alias CNC.Configuration.Changes
      [default] = Profiles.list(db)
      {:ok, slow} = Profiles.create(db, "Slow", :fake_sim, default.id)

      :ok =
        Changes.stage(db, [
          %{part: :build, target: nil, path: "axes/x/steps_per_mm", from: "80.000", to: "100"},
          %{
            part: :profile,
            target: default.id,
            path: "axes/x/max_rate_mm_per_min",
            from: "3000.000",
            to: "2500"
          },
          %{
            part: :profile,
            target: default.id,
            path: "axes/y/acceleration_mm_per_sec2",
            from: "500.000",
            to: "fast"
          },
          %{
            part: :profile,
            target: slow.id,
            path: "axes/x/max_rate_mm_per_min",
            from: "3000.000",
            to: "1000"
          }
        ])

      {:ok, %{applied: applied, errors: errors, restart?: false}} =
        Configuration.apply(m, db, ctl, Changes.list(db))

      assert length(applied) == 3
      assert [{_, {:not_applied, _}}] = Map.to_list(errors)
      # What failed stays staged
      assert [%{path: "axes/y/acceleration_mm_per_sec2"}] = Changes.list(db)

      assert FluidNC.get(m, "axes/x/steps_per_mm") == {:ok, "100"}
      assert FluidNC.get(m, "axes/x/max_rate_mm_per_min") == {:ok, "2500"}

      assert Enum.find(Profiles.list(db), &(&1.id == slow.id)).values[
               "axes/x/max_rate_mm_per_min"
             ] == "1000"

      # One write to the controller for the running parts
      assert [%{reason: "Changed 2 values (the build, profile Default)"}] = History.list(db, "c1")
    end

    test "a staged value that changed since is flagged stale", %{db: db, ctl: ctl} do
      alias CNC.Configuration.{Build, Changes}
      c = %{part: :build, target: nil, path: "axes/x/steps_per_mm", from: "80.000", to: "100"}
      :ok = Changes.stage(db, [c])
      assert Configuration.stale(db, ctl, Changes.list(db)) == []
      Build.change(db, %{"axes/x/steps_per_mm" => "90"}, "Elsewhere")
      assert Configuration.stale(db, ctl, Changes.list(db)) == [Changes.key(c)]
    end
  end

  defp eventually(fun, timeout \\ 5000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
