defmodule CNC.ControllersTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias CNC.{Boards, Controllers, Machine}
  alias CNC.Controllers.Profile

  describe "boards" do
    test "every board renders a config with its own pins and stepping engine" do
      assert Boards.config(:esp32_devkit) =~ "engine: RMT"
      assert Boards.config(:esp32_devkit) =~ "step_pin: gpio.25"
      assert Boards.config(:esp32_devkit) =~ "limit_neg_pin: gpio.16:low:pu"

      six = Boards.config(:six_x)
      assert six =~ "engine: I2S_STREAM"
      assert six =~ "step_pin: I2SO.2"
      assert six =~ "disable_pin: I2SO.0"
      assert six =~ "limit_pos_pin: gpio.33:low"
      assert six =~ "toolsetter_pin: gpio.36:low"
      assert six =~ "i2so:"

      # The sim: real-time stepping, no switches, homing just sets position
      sim = Boards.config(:fluidnc_sim)
      assert sim =~ "engine: timed"
      refute sim =~ "limit_"
      assert sim =~ "cycle: -1"

      # Same machine everywhere
      for id <- Boards.ids(), do: assert(Boards.config(id) =~ "max_travel_mm: 1250")

      # Which links each board's hardware can use, the usual one first
      assert Boards.links(:fluidnc_sim) == [:fluidnc_sim]
      assert Boards.links(:fake_sim) == [:fake_sim]
      assert Boards.links(:esp32_devkit) == [:serial, :tcp]
      assert Boards.links(:six_x) == [:serial, :tcp]
    end
  end

  describe "profiles" do
    test "survive a JSON round trip" do
      p = %Profile{
        id: "ab2c",
        name: "Bench",
        board: :esp32_devkit,
        link: %{type: :serial, port: "/dev/cu.x", speed: 115_200}
      }

      assert {:ok, ^p} = p |> Jason.encode!() |> Jason.decode!() |> Profile.from_json()

      assert Profile.from_json(%{"id" => "x", "name" => "n", "board" => "nope", "link" => %{}}) ==
               :error
    end
  end

  describe "controllers" do
    setup %{tmp_dir: dir} do
      id = System.unique_integer([:positive])
      machine = :"controllers_machine_#{id}"

      start_supervised!(
        Supervisor.child_spec({Machine, name: machine, topic: "ctl-#{id}", link: nil},
          id: machine
        )
      )

      %{dir: dir, machine: machine}
    end

    defp start_controllers(%{dir: dir, machine: machine}, opts \\ []) do
      name = :"controllers_#{System.unique_integer([:positive])}"

      opts =
        Keyword.merge([name: name, data_dir: dir, machine: machine, overridden?: false], opts)

      start_supervised!(Supervisor.child_spec({Controllers, opts}, id: name))
      name
    end

    test "first run: sim (when built) and fake sim, the first one active and connected", ctx do
      c = start_controllers(ctx)
      profiles = Controllers.list(c)
      assert %{board: :fake_sim, link: %{type: :fake_sim}} = List.last(profiles)
      assert Controllers.active(c) == hd(profiles)
      assert File.exists?(Path.join(ctx.dir, "controllers.json"))
      assert eventually(fn -> Machine.status(ctx.machine).connected? end, 5000)
    end

    test "selecting switches the machine's link; the choice survives a restart", ctx do
      c = start_controllers(ctx)
      fake = Enum.find(Controllers.list(c), &(&1.link.type == :fake_sim))

      :ok = Controllers.select(c, fake.id)
      assert eventually(fn -> Machine.status(ctx.machine).adapter == "FakeSim" end, 5000)
      # A fresh connection: locked until unlocked, as on any connect
      assert eventually(fn -> Machine.status(ctx.machine).state == :alarm end, 5000)

      stop_supervised!(c)
      c2 = start_controllers(ctx)
      assert Controllers.active(c2).id == fake.id
      assert Controllers.list(c2) |> Enum.map(& &1.id) |> Enum.member?(fake.id)
      assert Controllers.select(c2, "nope") == {:error, :not_found}
    end

    test "adding profiles: board defaults for the link, serial needs a port", ctx do
      c = start_controllers(ctx)

      assert Controllers.add(c, %{name: "Bench", board: :esp32_devkit}) ==
               {:error, :serial_port_required}

      {:ok, bench} =
        Controllers.add(c, %{
          name: "Bench",
          board: :esp32_devkit,
          link: %{type: :serial, port: "/dev/cu.x"}
        })

      assert bench.link == %{type: :serial, port: "/dev/cu.x", speed: 115_200}

      {:ok, wifi} =
        Controllers.add(c, %{name: "6x", board: :six_x, link: %{type: :tcp, host: "cnc6x.local"}})

      assert wifi.link.port == 23
      assert Controllers.add(c, %{name: "?", board: :nope}) == {:error, :unknown_board}

      # A link the board can't use is refused (the sim runs on this computer)
      assert Controllers.add(c, %{
               name: "x",
               board: :fluidnc_sim,
               link: %{type: :serial, port: "/dev/x"}
             }) ==
               {:error, {:link_not_supported, :serial}}

      assert Controllers.add(c, %{name: "x", board: :six_x, link: %{type: :tcp}}) ==
               {:error, :tcp_host_required}

      assert Enum.map(Controllers.list(c), & &1.name) |> Enum.take(-2) == ["Bench", "6x"]
    end

    test "an override (CNC_LINK, tests) leaves the machine alone and refuses selecting", ctx do
      c = start_controllers(ctx, overridden?: true)
      assert Controllers.overridden?(c)
      assert Controllers.active(c) == nil
      assert Controllers.select(c, hd(Controllers.list(c)).id) == {:error, :overridden}
      refute Machine.status(ctx.machine).connected?
    end
  end

  describe "Machine.connect" do
    test "switching to no controller and back" do
      id = System.unique_integer([:positive])
      m = :"connect_machine_#{id}"

      start_supervised!(
        Supervisor.child_spec(
          {Machine, name: m, topic: "conn-#{id}", link: {CNC.Link.FakeSim, []}},
          id: m
        )
      )

      assert eventually(fn -> Machine.status(m).state == :alarm end, 5000)
      :ok = Machine.connect(m, nil)
      assert %{state: :disconnected, connected?: false} = Machine.status(m)
      Process.sleep(300)
      assert Machine.status(m).state == :disconnected

      :ok = Machine.connect(m, {CNC.Link.FakeSim, []})
      assert eventually(fn -> Machine.status(m).state == :alarm end, 5000)
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
