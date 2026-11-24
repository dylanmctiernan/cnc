defmodule CNC.MachineCase do
  @moduledoc """
  Shared by the CNC.Machine test modules (split by area so they run in
  parallel): start a Machine, play the controller (report, ok, connect),
  and small waits.
  """
  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias CNC.Machine

  using do
    quote do
      import CNC.MachineCase
      alias CNC.Machine
      alias CNC.Machine.State

      @jog_cancel 0x85
    end
  end

  def start_machine(link, topic) do
    spec = {Machine, name: nil, link: link, topic: topic}
    start_supervised!(Supervisor.child_spec(spec, id: make_ref()))
  end

  def report(m, state, {x, y}),
    do: send(m, {:link, :line, "<#{state}|MPos:#{x}.000,#{y}.000,0.000|FS:0,0>"})

  def ok(m), do: send(m, {:link, :line, "ok"})

  # First status after (re)connect: Machine then asks for settings ($$).
  # Play the controller: send the given setting lines, then ok.
  def connect(m, state, pos, settings \\ [], info \\ []) do
    report(m, state, pos)
    assert_receive {:line, "$$"}
    assert_receive {:line, "$I"}
    for line <- settings, do: send(m, {:link, :line, line})
    ok(m)
    for line <- info, do: send(m, {:link, :line, line})
    ok(m)
  end

  def idle(m) do
    connect(m, "Idle", {0, 0})
    :ok = Machine.unlock(m)
    assert_receive {:line, "$X"}
    ok(m)
    assert Machine.status(m).state == :idle
  end

  # Already idle (unlocked); report a new position including Z.
  def idle_at(m, {x, y}, z) do
    send(m, {:link, :line, "<Idle|MPos:#{x}.000,#{y}.000,#{z}.000|FS:0,0>"})
    Machine.status(m)
  end

  # Ack every jog line for `ms` (with heartbeats), return how many were sent.
  def count_jog_lines(m, ms, n \\ 0) do
    receive do
      {:line, "$J=" <> _} ->
        ok(m)
        count_jog_lines(m, ms, n + 1)
    after
      50 ->
        Machine.jog_heartbeat(m)
        if ms <= 0, do: n, else: count_jog_lines(m, ms - 50, n)
    end
  end

  def keep_alive(m, ms) when ms <= 0, do: Machine.status(m)

  def keep_alive(m, ms) do
    Machine.jog_heartbeat(m)
    Process.sleep(50)
    keep_alive(m, ms - 50)
  end

  # Discard real-time bytes already sent (e.g. repeat cancels while stopping).
  def flush_rt do
    receive do
      {:rt, _} -> flush_rt()
    after
      50 -> :ok
    end
  end

  def drain(acc \\ []) do
    receive do
      {:machine, state} -> drain([state | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def eventually(fun, timeout \\ 1000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(10) && eventually(fun, timeout - 10)
    end
  end
end
