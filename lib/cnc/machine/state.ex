defmodule CNC.Machine.State do
  @moduledoc """
  Public snapshot of the machine, as returned by `CNC.Machine.status/1` and
  broadcast as `{:machine, %State{}}`.

    * `state` — host view: `:disconnected | :connecting | :alarm | :idle |
      :jogging | :homing | :busy`
    * `controller` — the controller's own last reported state
      (`CNC.Grbl.Status` state atom), `nil` until the first report
    * `substate` — e.g. the `1` in `Hold:1` / `Door:1`
    * `mpos`/`wpos` — last *reported* positions, never commanded ones
    * `wco` — work coordinate offset, once the controller has reported it
    * `feed` — reported feed rate (mm/min)
    * `buffer` — `{planner_blocks_free, serial_bytes_free}` (`Bf`), if reported
    * `awaiting_ack` — lines sent that the controller hasn't acked yet
    * `moving?` — the machine may still be moving: the controller reports
      Run, Jog or Home, or motion was sent since the last report that
      followed all acks. Position-based actions (go to work zero) wait for false.
    * `alarm` — why we're locked in `:alarm`: `:connect` (fresh connection,
      position not trusted), `:reset` (controller rebooted), `{:alarm, code}`
      (controller `ALARM:N`), or `:reported` (status said Alarm)
    * `last_error` — `{:error, code}` from a rejected line,
      `{:jog, :heartbeat_lost}`, or `{:link, :no_response}` (no status
      reports for a while: the link was dropped and is reconnecting)
    * `speed` — `{xy, z}` in mm/min: the controller's reported feed split
      along the direction of travel, X/Y across the bed (the hypotenuse) and
      Z vertical. `{0.0, 0.0}` when stopped.
    * `max_rate` — `{x, y, z}` max rates in mm/min, from the controller's
      `$110`–`$112`, else the configured machine maximum
    * `jog` — current held-key vector `{dx, dy, dz}`, `{0, 0, 0}` when not jogging
    * `travel` — `{{x0, x1}, {y0, y1}, {z0, z1}}` in mm, the limits the host
      clamps jogs to (the controller's soft limits remain authoritative)
    * `travel_source` — `:controller` once read from `$130`–`$132` after
      connecting, otherwise `:config` (the fallback)
    * `controller_info` — `%{firmware: "grblHAL" | "FluidNC" | "Grbl" | ...,
      version: binary | nil, simulated?: boolean}` from `$I` and the boot
      banner; `simulated?` is true for the sims (FakeSim, FluidNCSim) and for controllers
      reporting `[DRIVER:Simulator]` (the grblHAL simulator)
    * `settings_rev` — increases each time the settings are (re)read; fetch
      them with `CNC.Machine.settings/1`
    * `settings_write` — results of the last `write_settings/2`:
      `%{n => :pending | :ok | {:error, code}}`
    * `homing_enabled?` — from the controller's `$22`: `false` means `$H`
      will be refused (`error:5`); `nil` if it doesn't report `$22`
    * `travel_issues` — `[{axis, reported_mm, max_mm}]` for axes where the
      controller claimed more travel than the machine physically has (capped)
  """

  @type t :: %__MODULE__{}

  defstruct state: :disconnected,
            connected?: false,
            adapter: nil,
            controller: nil,
            substate: nil,
            mpos: nil,
            wpos: nil,
            wco: nil,
            feed: nil,
            speed: {0.0, 0.0},
            max_rate: nil,
            buffer: nil,
            awaiting_ack: 0,
            moving?: false,
            alarm: nil,
            last_error: nil,
            tier: :normal,
            jog: {0, 0, 0},
            travel: nil,
            travel_source: :config,
            travel_issues: [],
            homing_enabled?: nil,
            controller_info: %{firmware: nil, version: nil, simulated?: false},
            settings_rev: 0,
            settings_write: %{}
end
