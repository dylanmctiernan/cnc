defmodule CNC.Machine.ProtocolPropertyTest do
  @moduledoc """
  The machine's state machine checked against its written protocol
  (`CNC.Machine.Protocol`): random command sequences against the real
  server driving the fake sim. OTP's debug hook (`:sys.install/2`) reports
  every event the server handles, the state it handled it in, the state it
  went to, and every reply, so nothing is inferred. After each run:

    * every call accepted or refused as the table says
    * every change of state is one the table allows
    * never more than 127 bytes of a job unacked
    * an accepted Abort always ends locked

  A failing sequence shrinks to the shortest one that still fails.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CNC.Machine.Protocol

  # Small enough to finish quickly at the fake sim's feeds; Z stays in its
  # travel (-100..0).
  @program "G21 G90\nG0 Z0\nG1 X4 F3000\nG1 Y4\nG1 Z-1 F600\nG1 X0 F3000\nG0 Z0\n"

  describe "the protocol table" do
    test "every state can be reached from disconnected" do
      reached = reach([:disconnected], MapSet.new([:disconnected]))
      assert MapSet.new(Protocol.states()) == reached
    end

    test "a running job only ends: Ready, locked, rebooting or lost" do
      assert Enum.sort(Protocol.next(:running)) == [:alarm, :connecting, :disconnected, :idle]
      refute Protocol.accepts?(:running, :jog)
      refute Protocol.accepts?(:running, :raw)
      refute Protocol.accepts?(:running, :run)
      assert Protocol.accepts?(:running, :feed_hold) == :if_connected
      assert Protocol.accepts?(:running, :abort) == :if_connected
    end

    defp reach([], seen), do: seen

    defp reach([s | rest], seen) do
      new = Enum.reject(Protocol.next(s), &MapSet.member?(seen, &1))
      reach(rest ++ new, Enum.into(new, seen))
    end
  end

  property "the server keeps to the protocol, whatever it's asked" do
    check all(commands <- list_of(command(), min_length: 1, max_length: 30), max_runs: 25) do
      {m, events} = run([:unlock | List.flatten(commands)])
      check_calls(events)
      check_transitions(events)
      assert Enum.all?(events, &budget_ok?/1), "more than 127 bytes of a job in flight"
      :gen_statem.stop(m)
    end
  end

  ## Commands

  # Weighted toward what exercises the most: running a file and waiting
  # long enough for it to finish, jogs that arrive mid-jog, Hold/Resume,
  # Abort, and the occasional reset or reconnect.
  defp command do
    frequency([
      {3, constant(:unlock)},
      {1, constant(:home)},
      {3,
       map(
         member_of([{1, 0, 0}, {0, -1, 0}, {0, 0, 1}, {1, 1, 0}]),
         &[{:jog, &1, :fast}, {:jog, &1, :normal}]
       )},
      {1, constant(:jog_heartbeat)},
      {2, constant(:jog_stop)},
      {1, constant({:jog_step, {1, 0, 0}, 1})},
      {2, constant(:feed_hold)},
      {2, constant(:resume)},
      {1, constant(:reset)},
      {4, constant({:run, "square.nc", @program})},
      {2, constant(:abort)},
      {1, member_of([{:raw, "G0 X1"}, {:raw, "$$"}, {:raw, "?"}])},
      {1, constant({:work_position, [x: 0.0]})},
      {1, constant(:go_to_work_zero)},
      {1, member_of([{:feed_override, :plus10}, {:feed_override, :reset}])},
      {1, constant({:upload, "a.yaml", "a: 1\n"})},
      {1, constant({:connect, {CNC.Link.FakeSim, homing_ms: 30}})},
      {3, map(integer(0..120), &{:sleep, &1})},
      {3, map(integer(400..1800), &{:sleep, &1})}
    ])
  end

  # Run the sequence, then wait a moment for anything in motion to settle,
  # and collect what the server reported (with the job's bytes in flight
  # sampled after each step).
  defp run(commands) do
    {:ok, m} =
      CNC.Machine.Server.start_link(
        name: nil,
        link: {CNC.Link.FakeSim, homing_ms: 30},
        topic: "protocol-#{System.unique_integer([:positive])}"
      )

    me = self()

    :sys.install(
      m,
      {fn acc, event, _ ->
         send(me, {:dbg, event})
         acc
       end, nil}
    )

    Process.sleep(150)
    # The first status locks it; then the commands
    true = eventually(fn -> elem(:sys.get_state(m), 0) == :alarm end)

    for command <- commands do
      perform(m, command)
      send(me, {:bytes, job_bytes(m)})
    end

    Process.sleep(200)
    {m, collect([])}
  end

  defp perform(_m, {:sleep, ms}), do: Process.sleep(ms)

  # An accepted Abort always ends locked
  defp perform(m, :abort) do
    if :gen_statem.call(m, :abort, 2000) == :ok do
      assert eventually(fn -> elem(:sys.get_state(m), 0) == :alarm end),
             "Abort accepted but the machine didn't lock"
    end
  end

  defp perform(m, request), do: :gen_statem.call(m, request, 5000)

  defp job_bytes(m) do
    case :sys.get_state(m) do
      {_state, %{job: %{bytes: bytes}}} -> bytes
      _ -> 0
    end
  end

  defp collect(acc) do
    receive do
      {:dbg, event} -> collect([event | acc])
      {:bytes, b} -> collect([{:bytes, b} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  ## Checks

  # Each call: refused exactly when the table says the state doesn't take it.
  defp check_calls(events) do
    replies = for {:out, reply, from} <- events, into: %{}, do: {from, reply}

    for {:consume, {{:call, from}, request}, state, _next} <- events,
        request != :status do
      reply = Map.get(replies, from)
      refused? = reply == {:error, {:invalid_state, state}}

      case Protocol.accepts?(state, effective(request)) do
        true ->
          refute refused?, "#{inspect(request)} refused in #{state}, but the protocol accepts it"

        false ->
          assert refused?,
                 "#{inspect(request)} answered #{inspect(reply)} in #{state}, but the protocol refuses it"

        :if_connected ->
          :ok
      end
    end
  end

  # A zero jog is a stop
  defp effective({:jog, {0, 0, 0}, _}), do: :jog_stop
  defp effective(request), do: request

  defp check_transitions(events) do
    for {:consume, event, from, to} <- events, from != to do
      assert Protocol.transition?(from, to),
             "#{from} → #{to} (on #{inspect(event, limit: 4)}) isn't in the protocol"
    end
  end

  defp budget_ok?({:bytes, b}), do: b <= 127
  defp budget_ok?(_), do: true

  defp eventually(fun, timeout \\ 2000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
