defmodule CNC.GrblhalSimTest do
  @moduledoc """
  CNC.Machine over TCP against the real grblHAL simulator.

      docker compose up -d grblhal-sim
      GRBLHAL_SIM=localhost:2323 mix test --only grblhal_sim

  The simulator serves one client at a time (the newest connection takes
  over), so these run synchronously and nothing else should be connected.
  Its position persists between tests, so moves are chosen relative to
  wherever it is.
  """
  use ExUnit.Case, async: false
  @moduletag :grblhal_sim

  alias CNC.Machine
  alias CNC.Machine.State

  setup do
    [host, port] = String.split(System.get_env("GRBLHAL_SIM", "localhost:2323"), ":")
    transport = {CNC.Transport.TCP, host: host, port: String.to_integer(port)}
    topic = "grblhal-#{System.unique_integer([:positive])}"
    spec = {Machine, name: nil, transport: transport, topic: topic}
    m = start_supervised!(Supervisor.child_spec(spec, id: make_ref()))

    assert eventually(fn -> Machine.status(m).travel_source == :controller end, 3000),
           "no settings from grblHAL sim at #{host}:#{port} (docker compose up -d grblhal-sim)"

    %{m: m}
  end

  test "connects locked, reads travel from $130-$132, unlocks", %{m: m} do
    assert %State{
             state: :alarm,
             alarm: :connect,
             travel: {{+0.0, 1250.0}, {+0.0, 1250.0}, _},
             homing_enabled?: false
           } = Machine.status(m)

    :ok = Machine.unlock(m)
    assert eventually(fn -> Machine.status(m).state == :idle end)
  end

  test "continuous jog moves, jog_stop decelerates to a stop", %{m: m} do
    unlock(m)
    {x0, y0, _} = Machine.status(m).mpos
    dir = if x0 < 600, do: 1, else: -1

    :ok = Machine.jog(m, {dir, 0}, :fast)
    keep_alive(m, 500)
    assert Machine.status(m).controller == :jog
    :ok = Machine.jog_stop(m)

    assert eventually(fn -> Machine.status(m).controller == :idle end, 3000)
    %State{mpos: {x1, y1, _}} = Machine.status(m)
    assert (x1 - x0) * dir > 5
    assert_in_delta y1, y0, 0.01

    # Stopped means stopped: no lingering queued motion.
    Process.sleep(300)
    assert Machine.status(m).mpos == {x1, y1, elem(Machine.status(m).mpos, 2)}
  end

  test "losing the heartbeat stops the real firmware", %{m: m} do
    unlock(m)
    {_, y0, _} = Machine.status(m).mpos
    dir = if y0 < 600, do: 1, else: -1

    :ok = Machine.jog(m, {0, dir}, :normal)
    # no heartbeats
    assert eventually(fn -> Machine.status(m).last_error == {:jog, :heartbeat_lost} end, 500)
    assert eventually(fn -> Machine.status(m).controller == :idle end, 3000)

    # 250 ms dead-man + deceleration at 20 mm/s: well under 20 mm.
    {_, y1, _} = Machine.status(m).mpos
    assert abs(y1 - y0) < 20
  end

  test "step moves exactly", %{m: m} do
    unlock(m)
    {x0, y0, _} = Machine.status(m).mpos
    dir = if y0 < 600, do: 1, else: -1

    :ok = Machine.jog_step(m, {0, dir}, 10)

    assert eventually(
             fn -> abs(elem(Machine.status(m).mpos, 1) - (y0 + 10 * dir)) < 0.001 end,
             3000
           )

    assert elem(Machine.status(m).mpos, 0) == x0
  end

  test "Z steps down and jogs back up, never above the top", %{m: m} do
    unlock(m)
    {_, _, z0} = Machine.status(m).mpos

    :ok = Machine.jog_step(m, {0, 0, -1}, 10)
    assert eventually(fn -> abs(elem(Machine.status(m).mpos, 2) - (z0 - 10)) < 0.001 end, 3000)

    # Hold Z+ for longer than it takes to reach the top: the clamp stops it there.
    :ok = Machine.jog(m, {0, 0, 1}, :fast)
    keep_alive(m, 2000)
    :ok = Machine.jog_stop(m)
    assert eventually(fn -> Machine.status(m).controller == :idle end, 3000)
    assert elem(Machine.status(m).mpos, 2) <= 0.0
    assert elem(Machine.status(m).mpos, 2) > -0.01
  end

  test "analog jog: half deflection moves about half as far", %{m: m} do
    unlock(m)
    {x0, _, _} = Machine.status(m).mpos
    dir = if x0 < 600, do: 1, else: -1

    distance = fn scale ->
      {start, _, _} = Machine.status(m).mpos
      :ok = Machine.jog(m, {dir * scale, 0, 0}, :normal)
      keep_alive(m, 1000)
      :ok = Machine.jog_stop(m)
      assert eventually(fn -> Machine.status(m).controller == :idle end, 3000)
      abs(elem(Machine.status(m).mpos, 0) - start)
    end

    full = distance.(1.0)
    half = distance.(0.5)
    assert full > 10
    assert_in_delta half / full, 0.5, 0.15
  end

  test "work zero: set, move away, go back (Z lifted first)", %{m: m} do
    unlock(m)
    {x0, y0, _} = Machine.status(m).mpos
    dir = if x0 < 600, do: 1, else: -1

    :ok = Machine.set_work_zero(m, [:x, :y])
    assert eventually(fn -> match?({+0.0, +0.0, _}, Machine.status(m).wpos) end, 3000)

    :ok = Machine.jog_step(m, {dir, dir, -1}, 10)
    # Refused until the step has finished; then it goes.
    assert eventually(fn -> Machine.go_to_work_zero(m) == :ok end, 8000)

    assert eventually(
             fn ->
               {x, y, z} = Machine.status(m).mpos
               abs(x - x0) < 0.002 and abs(y - y0) < 0.002 and z > -1.01
             end,
             5000
           )
  end

  test "soft reset reboots the controller and the host relocks", %{m: m} do
    unlock(m)
    :ok = Machine.reset(m)

    assert eventually(
             fn -> match?(%State{state: :alarm, alarm: :reset}, Machine.status(m)) end,
             3000
           )

    assert Enum.any?(Machine.console(m), &match?(%{dir: :in, text: "GrblHAL" <> _}, &1))
  end

  defp unlock(m) do
    :ok = Machine.unlock(m)
    assert eventually(fn -> Machine.status(m).state == :idle end)
  end

  defp keep_alive(_m, ms) when ms <= 0, do: :ok

  defp keep_alive(m, ms) do
    Machine.jog_heartbeat(m)
    Process.sleep(100)
    keep_alive(m, ms - 100)
  end

  defp eventually(fun, timeout \\ 1000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
