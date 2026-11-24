defmodule CNC.FluidNCSimCase do
  @moduledoc """
  Shared by the FluidNC sim test modules (split so they run in parallel):
  each test starts its own FluidNC in a temporary directory.
  """
  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias CNC.Machine

  using do
    quote do
      import CNC.FluidNCSimCase
      alias CNC.Machine
      alias CNC.Machine.State

      @moduletag :fluidnc_sim
      @moduletag :tmp_dir

      setup :start_fluidnc
    end
  end

  def start_fluidnc(%{tmp_dir: dir}) do
    transport =
      {CNC.Transport.FluidNCSim,
       executable: Path.expand(".fluidnc/bin/fluidnc"),
       config: Path.expand("priv/fluidnc/sim.yaml"),
       run_dir: dir}

    topic = "fluidnc-#{System.unique_integer([:positive])}"
    spec = {Machine, name: nil, transport: transport, topic: topic}
    m = start_supervised!(Supervisor.child_spec(spec, id: make_ref()))
    assert eventually(fn -> Machine.status(m).travel_source == :controller end, 5000)
    %{m: m}
  end

  def unlock(m) do
    :ok = Machine.unlock(m)
    assert eventually(fn -> Machine.status(m).state == :idle end)
  end

  def keep_alive(_m, ms) when ms <= 0, do: :ok

  def keep_alive(m, ms) do
    Machine.jog_heartbeat(m)
    Process.sleep(50)
    keep_alive(m, ms - 50)
  end

  def eventually(fun, timeout \\ 1000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
