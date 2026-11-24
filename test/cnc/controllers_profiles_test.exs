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
    [before | _] = Config.history(db, "c1")
    {:ok, _} = Config.restore(m, db, "c1", before)

    assert {:ok, %{matches?: false, differences: [%{path: "axes/x/max_rate_mm_per_min"}]}} =
             Profiles.check(m, db, ctl)

    :ok = Profiles.take_file(m, db, ctl)
    assert {:ok, %{matches?: true}} = Profiles.check(m, db, ctl)
    assert [%{values: %{"axes/x/max_rate_mm_per_min" => "3000.000"}}] = Profiles.list(db, "c1")
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

  test "loading another file directly is an override", %{m: m, db: db, ctl: ctl} do
    {:ok, _} = Config.save_running_as(m, "mine.yaml")
    :ok = Profiles.use_file(m, "mine.yaml")

    assert eventually(fn ->
             match?({:ok, %{override?: true, loaded: "mine.yaml"}}, Profiles.check(m, db, ctl))
           end)

    assert Profiles.set(m, db, ctl, [{"axes/x/max_rate_mm_per_min", "1"}]) == {:error, :override}
    assert %{matches?: false} = Profiles.last_seen(db, "c1")
  end

  defp eventually(fun, timeout \\ 5000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
