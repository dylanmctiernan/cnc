defmodule CNC.Controllers.ProfilesTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias CNC.Controllers.{Config, Controller, Profiles, Yaml}
  alias CNC.Machine

  doctest Yaml

  test "yaml: set by path (any case, adding what's missing) and write back out" do
    tree = Yaml.parse("name: R\naxes:\n  X:\n    steps_per_mm: 80\n")
    tree = tree |> Yaml.put("axes/x/steps_per_mm", "100") |> Yaml.put("axes/x/homing/cycle", "2")
    tree = Yaml.put(tree, "start/must_home", "false")

    assert Yaml.render(tree) ==
             "name: R\naxes:\n  X:\n    steps_per_mm: 100\n    homing:\n      cycle: 2\nstart:\n  must_home: false\n"

    assert Yaml.parse(Yaml.render(tree)) == tree
    # Every board's config survives a round trip
    for board <- CNC.Boards.ids() do
      text = CNC.Boards.config(board)
      assert Config.parse(Yaml.render(Yaml.parse(text))) == Config.parse(text)
    end
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
    :ok = Profiles.ensure(m, db, "c1")
    %{m: m, db: db, ctl: ctl}
  end

  test "first contact: Default from what it runs, selected; its file matches", %{
    m: m,
    db: db,
    ctl: ctl
  } do
    assert [%{name: "Default", values: values}] = Profiles.list(db, "c1")
    assert values["axes/x/max_rate_mm_per_min"] == "3000.000"
    refute Map.has_key?(values, "stepping/engine")
    assert %{name: "Default"} = Profiles.selected(db, "c1")

    # Its file holds what the profile would write: it matches, though the
    # app didn't write it
    assert {:ok, %{matches?: true, loaded: "config.yaml", written_by_app?: false}} =
             Profiles.check(m, db, ctl)

    assert Profiles.last_seen(db, "c1") == %{name: "Default", matches?: true}
  end

  test "a change applies live, goes into the profile and the file; wiring is refused", %{
    m: m,
    db: db,
    ctl: ctl
  } do
    assert {:ok, %{applied: %{"axes/x/max_rate_mm_per_min" => _}, errors: errors}} =
             Profiles.set(m, db, ctl, [
               {"axes/x/max_rate_mm_per_min", "2500"},
               {"axes/y/acceleration_mm_per_sec2", "fast"},
               {"stepping/engine", "RMT"}
             ])

    assert %{
             "stepping/engine" => :wiring,
             "axes/y/acceleration_mm_per_sec2" => {:not_applied, _}
           } = errors

    assert Config.get(m, "axes/x/max_rate_mm_per_min") == {:ok, "2500"}
    assert [%{values: %{"axes/x/max_rate_mm_per_min" => "2500"}}] = Profiles.list(db, "c1")
    {:ok, file} = Config.show(m, "config.yaml")
    assert file =~ ~s(profile "Default")
    assert file =~ "max_rate_mm_per_min: 2500"
    assert {:ok, %{matches?: true, written_by_app?: true}} = Profiles.check(m, db, ctl)
    # The file's earlier text is in the history
    assert [%{file: "config.yaml"}] = Config.history(db, "c1")
    assert Profiles.drift(m, db, "c1") == {:ok, []}
  end

  test "switching writes the one file and restarts; the other profile's values come back", %{
    m: m,
    db: db,
    ctl: ctl
  } do
    [default] = Profiles.list(db, "c1")
    {:ok, fast} = Profiles.create(db, "c1", "Fast accel", :fake_sim, default.id)
    assert Profiles.create(db, "c1", "fast ACCEL", :fake_sim, default.id) == {:error, :exists}
    {:ok, board} = Profiles.create(db, "c1", "Board", :fake_sim, :board)
    assert board.values["axes/x/max_rate_mm_per_min"]

    assert Profiles.diff(:fake_sim, default, fast) == []
    {:ok, _} = Profiles.edit(db, "c1", fast.id, [{"axes/x/acceleration_mm_per_sec2", "800"}])
    fast = Enum.find(Profiles.list(db, "c1"), &(&1.id == fast.id))

    assert [%{path: "axes/x/acceleration_mm_per_sec2", to: "800"}] =
             Profiles.diff(:fake_sim, default, fast)

    :ok = Profiles.switch(m, db, ctl, fast.id)
    assert eventually(fn -> Machine.status(m).state == :alarm end)
    assert eventually(fn -> match?({:ok, %{matches?: true}}, Profiles.check(m, db, ctl)) end)
    assert %{name: "Fast accel"} = Profiles.selected(db, "c1")
    {:ok, _} = Profiles.set(m, db, ctl, [{"axes/x/acceleration_mm_per_sec2", "900"}])

    :ok = Profiles.switch(m, db, ctl, default.id)

    assert eventually(fn ->
             match?(
               {:ok, %{profile: %{name: "Default"}, matches?: true}},
               Profiles.check(m, db, ctl)
             )
           end)

    {:ok, accel} = Config.get(m, "axes/x/acceleration_mm_per_sec2")
    assert Config.same?(accel, "500")
    # Still one file on the controller
    assert {:ok, %{files: [%{name: "config.yaml"}]}} = Config.files(m)

    assert Profiles.delete(db, "c1", default.id) == {:error, :in_use}
    assert Profiles.rename(db, "c1", fast.id, "Default") == {:error, :exists}
    :ok = Profiles.rename(db, "c1", fast.id, "Quick")
    :ok = Profiles.delete(db, "c1", board.id)
    assert Enum.map(Profiles.list(db, "c1"), & &1.name) == ["Default", "Quick"]
  end

  test "the file differs (an earlier version restored): write the profile, or keep the file", %{
    m: m,
    db: db,
    ctl: ctl
  } do
    {:ok, _} = Profiles.set(m, db, ctl, [{"axes/x/max_rate_mm_per_min", "2500"}])
    {:ok, _} = Profiles.set(m, db, ctl, [{"axes/x/max_rate_mm_per_min", "2600"}])

    assert [%{version: 2, reason: "Changed 1 setting in profile Default"}, %{version: 1} = v1] =
             Config.history(db, "c1")

    {:ok, _} = Config.restore(m, db, "c1", v1)
    # (The page restarts the controller after restoring its file.)
    :ok = Config.activate(m, "config.yaml")
    assert eventually(fn -> Machine.status(m).state == :alarm end)

    {:ok, %{matches?: false, differences: diffs}} = Profiles.check(m, db, ctl)

    assert %{profile: "2600", controller: "2500"} =
             Enum.find(diffs, &(&1.path == "axes/x/max_rate_mm_per_min"))

    # The file's values win: they go into the profile, which is written
    :ok = Profiles.take_file(m, db, ctl)
    assert eventually(fn -> match?({:ok, %{matches?: true}}, Profiles.check(m, db, ctl)) end)
    assert [%{values: %{"axes/x/max_rate_mm_per_min" => "2500"}}] = Profiles.list(db, "c1")

    assert %{reason: "Kept the controller's values in profile Default"} =
             hd(Config.history(db, "c1"))
  end

  test "a profile's history: a version per change; restoring is a new version", %{
    m: m,
    db: db,
    ctl: ctl
  } do
    [default] = Profiles.list(db, "c1")
    {:ok, fast} = Profiles.create(db, "c1", "Fast", :fake_sim, default.id)
    {:ok, _} = Profiles.edit(db, "c1", fast.id, [{"axes/x/acceleration_mm_per_sec2", "800"}])
    :ok = Profiles.rename(db, "c1", fast.id, "Quick")

    quick = Enum.find(Profiles.list(db, "c1"), &(&1.id == fast.id))

    assert [
             %{version: 3, reason: "Renamed from Fast", diff: []},
             %{version: 2, reason: "Edited", diff: [%{path: "axes/x/acceleration_mm_per_sec2"}]},
             %{version: 1, reason: "Made as a copy of Default"}
           ] = quick.history

    assert [%{path: "axes/x/acceleration_mm_per_sec2", from: "800"}] =
             Profiles.restore_diff(db, "c1", fast.id, 2)

    :ok = Profiles.restore(m, db, ctl, fast.id, 2)
    quick = Enum.find(Profiles.list(db, "c1"), &(&1.id == fast.id))
    assert %{version: 4, reason: "Restored v1"} = hd(quick.history)
    assert quick.values["axes/x/acceleration_mm_per_sec2"] == "500.000"
    # Not the selected profile: nothing went to the controller
    assert Config.history(db, "c1") == []

    # The selected one: written, and recorded on the controller's side too
    {:ok, _} = Profiles.set(m, db, ctl, [{"axes/x/max_rate_mm_per_min", "2500"}])
    :ok = Profiles.restore(m, db, ctl, default.id, 1)
    assert eventually(fn -> match?({:ok, %{matches?: true}}, Profiles.check(m, db, ctl)) end)
    assert %{reason: "Restored profile Default to its v1"} = hd(Config.history(db, "c1"))
  end

  test "drift: a console change shows; keep it or put it back", %{m: m, db: db, ctl: ctl} do
    {:ok, _} = Machine.request(m, "$/axes/z/max_rate_mm_per_min=800")

    assert {:ok, [%{path: "axes/z/max_rate_mm_per_min", controller: "800"}]} =
             Profiles.drift(m, db, "c1")

    :ok = Profiles.put_back(m, db, "c1")
    assert Profiles.drift(m, db, "c1") == {:ok, []}

    {:ok, _} = Machine.request(m, "$/axes/z/max_rate_mm_per_min=700")
    :ok = Profiles.keep_drift(m, db, ctl)
    assert Profiles.drift(m, db, "c1") == {:ok, []}
    assert [%{values: %{"axes/z/max_rate_mm_per_min" => "700"}}] = Profiles.list(db, "c1")
  end

  test "another file loaded is an override; uploading your own replaces config.yaml", %{
    m: m,
    db: db,
    ctl: ctl
  } do
    {:ok, _} = Config.save_running_as(m, "mine.yaml")
    :ok = Config.activate(m, "mine.yaml")

    assert eventually(fn ->
             match?({:ok, %{override?: true, loaded: "mine.yaml"}}, Profiles.check(m, db, ctl))
           end)

    assert Profiles.set(m, db, ctl, [{"axes/x/max_rate_mm_per_min", "1"}]) == {:error, :override}
    assert %{matches?: false} = Profiles.last_seen(db, "c1")

    # The escape hatch: a file of your own becomes config.yaml
    {:ok, text} = Config.show(m, "mine.yaml")
    own = String.replace(text, "max_rate_mm_per_min: 3000.000", "max_rate_mm_per_min: 1500")
    assert Profiles.replace_file(m, db, ctl, "", "Pasted") == {:error, :not_a_config}
    :ok = Profiles.replace_file(m, db, ctl, own, "Uploaded own.yaml")

    assert eventually(fn ->
             match?(
               {:ok, %{loaded: "config.yaml", matches?: false, written_by_app?: false}},
               Profiles.check(m, db, ctl)
             )
           end)

    {:ok, %{differences: diffs}} = Profiles.check(m, db, ctl)
    assert Enum.any?(diffs, &(&1.controller == "1500"))

    # A file that leaves settings out differs by those too
    :ok =
      Profiles.replace_file(
        m,
        db,
        ctl,
        "name: Mine\naxes:\n  x:\n    max_rate_mm_per_min: 3000\n",
        "Pasted a config"
      )

    assert %{reason: "Pasted a config"} = hd(Config.history(db, "c1"))

    assert eventually(fn ->
             match?({:ok, %{written_by_app?: false}}, Profiles.check(m, db, ctl))
           end)

    {:ok, %{differences: diffs}} = Profiles.check(m, db, ctl)
    assert Enum.any?(diffs, &(&1.path == "axes/y/max_rate_mm_per_min" and &1.controller == nil))
  end

  defp eventually(fun, timeout \\ 5000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
