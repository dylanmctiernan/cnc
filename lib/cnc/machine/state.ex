defmodule CNC.Machine.State do
  @moduledoc """
  Public snapshot of the machine, as returned by `CNC.Machine.status/1` and
  broadcast as `{:machine, %State{}}`.

    * `state` — host view: `:disconnected | :connecting | :alarm | :idle |
      :jogging | :homing | :busy`
    * `controller` — the controller's own last reported state
      (`CNC.Grbl.Status` state atom), `nil` until the first report
    * `mpos`/`wpos` — last *reported* positions, never commanded ones
    * `alarm` — why we're locked in `:alarm`: `:connect` (fresh connection,
      position not trusted), `:reset` (controller rebooted), `{:alarm, code}`
      (controller `ALARM:N`), or `:reported` (status said Alarm)
    * `last_error` — `{:error, code}` from a rejected line, or
      `{:jog, :heartbeat_lost}`
    * `jog` — current held-key vector, `{0, 0}` when not jogging
  """

  @type t :: %__MODULE__{}

  defstruct state: :disconnected,
            connected?: false,
            adapter: nil,
            controller: nil,
            mpos: nil,
            wpos: nil,
            alarm: nil,
            last_error: nil,
            tier: :normal,
            jog: {0, 0}
end
