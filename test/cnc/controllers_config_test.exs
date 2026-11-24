defmodule CNC.Controllers.ConfigTest do
  use ExUnit.Case, async: true

  alias CNC.Controllers.Config
  alias CNC.Machine

  doctest Config

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

  defp eventually(fun, timeout) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
