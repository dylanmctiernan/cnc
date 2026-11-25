defmodule CNC.Machine.Protocol do
  @moduledoc """
  The machine's state machine, written down: its states, which state can
  follow which, and which calls each state accepts. One table, read by
  people and checked against the real server (`test/cnc/machine_protocol_property_test.exs`
  runs random command sequences against `CNC.Machine.Server` and the fake
  sim, and fails on any accept, refusal or transition not in here).

  A call a state doesn't accept is refused with `{:error, {:invalid_state, state}}`
  and changes nothing. Some calls are accepted in a state only when the
  controller is connected (`:connected`): the instant commands (Hold,
  Resume, Reset, feed override) and Abort.
  """

  @states [
    :disconnected,
    :connecting,
    :alarm,
    :idle,
    :jogging,
    :homing,
    :busy,
    :uploading,
    :running
  ]

  # Which state can follow which. Any state can drop to :disconnected (the
  # link is lost, or another controller is chosen) and to :connecting (the
  # controller rebooted: its banner) — except the two that come before a
  # connection. Everything that goes wrong lands in :alarm.
  @transitions %{
    disconnected: [:connecting],
    connecting: [:alarm, :disconnected],
    alarm: [:idle, :homing, :uploading, :connecting, :disconnected],
    idle: [:jogging, :homing, :busy, :running, :uploading, :alarm, :connecting, :disconnected],
    jogging: [:idle, :busy, :alarm, :connecting, :disconnected],
    homing: [:idle, :alarm, :connecting, :disconnected],
    busy: [:idle, :alarm, :connecting, :disconnected],
    uploading: [:idle, :alarm, :connecting, :disconnected],
    running: [:idle, :alarm, :connecting, :disconnected]
  }

  @all @states
  @connected Enum.reject(@states, &(&1 == :disconnected))

  # Calls, by name, and the states that accept them. `{:connected, states}`:
  # only while the link is up.
  @accepts %{
    status: @all,
    console: @all,
    settings: @all,
    connect: @all,
    jog_stop: @all,
    unlock: [:alarm, :idle],
    home: [:alarm, :idle],
    jog: [:idle, :jogging],
    jog_heartbeat: [:jogging],
    jog_step: [:idle],
    raw: [:alarm, :idle, :busy],
    work_position: [:idle],
    work_offset: [:idle],
    go_to_work_zero: [:idle],
    outline: [:idle],
    upload: [:alarm, :idle],
    request: [:alarm, :idle],
    run: [:idle],
    feed_hold: {:connected, @connected},
    resume: {:connected, @connected},
    reset: {:connected, @connected},
    feed_override: {:connected, @connected},
    abort: {:connected, [:running]}
  }

  @doc "The states."
  def states, do: @states

  @doc "States that may follow `state` (not counting staying put)."
  def next(state), do: Map.fetch!(@transitions, state)

  @doc "Whether `to` may directly follow `from` (staying put always may)."
  def transition?(from, from), do: true
  def transition?(from, to), do: to in Map.get(@transitions, from, [])

  @doc "The calls' names."
  def calls, do: Map.keys(@accepts)

  @doc """
  Whether `state` accepts `call` (a call name, or the request as sent:
  `:unlock`, `{:jog, vector, tier}`, ...): `true`, `false`, or
  `:if_connected` for the instant commands.
  """
  def accepts?(state, call) do
    case Map.fetch!(@accepts, name(call)) do
      {:connected, states} -> if state in states, do: :if_connected, else: false
      states -> state in states
    end
  end

  @doc "A request's call name: `{:jog, v, t}` → `:jog`."
  def name(call) when is_atom(call), do: call
  def name(call) when is_tuple(call), do: elem(call, 0)
end
