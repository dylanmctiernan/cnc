# CNC Host — Plan

Learning project: an Elixir host (Phoenix LiveView, later on Nerves / Raspberry Pi 5) that drives a home-built CNC router through a FluidNC controller.

## Phase 1 goal

**Manually move a simulated machine in X/Y with the arrow keys, and watch it move on a live top-down view of the bed.** No hardware required.

- Simulators only: the in-process Elixir Sim, then the real grblHAL firmware simulator over TCP.
- X/Y only. Z is not jogged or displayed in Phase 1 (protocol and state stay 3-axis so Z is a small addition later).
- Out of scope: real board (UART), Z, Nerves/Pi, storage, job streaming, toolpath preview, kiosk, config sync, probing.

---

## 1. Principles

- **Minimal abstractions, explicit seams.** One port, `CNC.Transport`, because it has real alternative implementations (Sim, TCP, later UART). No other behaviours until a second implementation exists.
- **Hexagonal shape, enforced by [Boundary](https://hexdocs.pm/boundary).** Pure protocol core, machine core owning state, adapters at the edge, UI on top. Boundary violations fail the build.
- **The UI only knows what the machine reports.** The visualization draws positions from status reports, never from what we commanded. Same code path for simulators and, later, the real machine.
- **Fail toward stopped.** Jogging uses short increments with a dead-man heartbeat. Hardware e-stop/limits (later) never depend on this code.
- **Terse code, small modules, tests on the parts that matter** (protocol parsing, state transitions, jog dead-man).

---

## 2. System context (Phase 1)

```
Browser: arrow keys + bed view
        │ LiveView (events in, state out)
        ▼
CNC host (Phoenix + OTP)
        │ CNC.Transport port, Grbl 1.1 text protocol
        ├──► CNC.Transport.Sim  (in-process fake, unit tests + default dev)
        └──► CNC.Transport.TCP  ──► grblHAL_sim (real Grbl firmware logic, Docker on Linux)

Later: CNC.Transport.UART ──► 6x board (FluidNC) ──► DM542T ──► NEMA 23
```

### Machine model (simulated, matches the planned build)

| Param | Value |
|---|---|
| X/Y travel | 0–1250 mm each |
| Max jog speed | 50 mm/s |
| Acceleration (grblHAL sim `$120/$121`) | 500 mm/s² |
| Origin | front-left, machine coords after homing |

---

## 3. Project layout

Single Phoenix app with boundaries. Nerves wrapper comes in a later phase.

```
cnc/                      # mix phx.new cnc --no-ecto --no-mailer --no-gettext
├── lib/cnc/
│   ├── grbl/             # boundary CNC.Grbl      — pure protocol
│   ├── transport/        # boundary CNC.Transport — link to the controller (Sim, TCP)
│   └── machine/          # boundary CNC.Machine   — state + jogging
├── lib/cnc.ex            # boundary CNC           — domain root; exports Machine
├── lib/cnc_app.ex        # boundary CNCApp        — supervision + config wiring only
├── lib/cnc_web/          # boundary CNCWeb       — LiveView UI + JS hooks
├── assets/js/hooks/      # JogKeys, BedView
├── docker/grblhal-sim/   # Dockerfile running grblHAL_sim -p 2323
└── test/
```

### Boundaries

| Boundary | deps | exports | Notes |
|---|---|---|---|
| `CNC.Grbl` | — | `Command`, `Response`, `Status`, `Realtime` | Pure functions. No processes, no IO |
| `CNC.Transport` | `CNC.Grbl` | `CNC.Transport` (behaviour), `Sim`, `TCP` | Port + adapters. Line-level transport |
| `CNC.Machine` | `CNC.Grbl`, `CNC.Transport` | `CNC.Machine` (API), `CNC.Machine.State` | Owns the connection. Only process that talks to Transport |
| `CNCWeb` | `CNC.Machine` | — | Must not reference `CNC.Transport` or `CNC.Grbl` |
| `CNC` (top) | — | `Machine` | Domain root. Grbl/Transport/Machine are its sub-boundaries |
| `CNCApp` (top) | `CNC`, `CNCWeb` | — | Supervision + config wiring only |

```elixir
# mix.exs
compilers: [:boundary] ++ Mix.compilers()
{:boundary, "~> 0.10", runtime: false}
```

`mix compile --warnings-as-errors` (part of `mix precommit`) turns a boundary violation into a build failure.

---

## 4. Grbl protocol (what Phase 1 needs)

Same protocol for grblHAL sim and FluidNC.

- **Framing:** ASCII lines ending `\n`.
- **Acks:** each line → `ok` or `error:N`, in order. `ok` = accepted into the planner, not executed.
- **Real-time bytes** (single byte, no newline, no ack): `?` status, `!` feed hold, `~` resume, `0x18` soft reset, `0x85` jog cancel.
- **Status:** `<State|MPos:x,y,z|FS:f,s|...>`. States: `Idle`, `Run`, `Jog`, `Hold:N`, `Alarm`, `Home`, `Door:N`, `Check`, `Sleep`. Optional fields (`WCO`, `Bf`, `Pn`, `Ov`) may appear; parse what's present, ignore unknown.
- **Async lines:** `ALARM:N`, `[MSG:...]`, boot banner.
- **Commands used:** `$X` unlock, `$H` home, `$J=G91 G21 X.. Y.. F..` jog.
- **On connect:** expect a banner; state unknown until the first status report. Machine typically starts in `Alarm` (needs `$X` or `$H`).

---

## 5. Simulators

Two layers, different jobs.

| Layer | What | Used for |
|---|---|---|
| `CNC.Transport.Sim` (Elixir) | Small in-process fake. Not a faithful firmware | Unit tests of `CNC.Machine`; fault injection; default `mix phx.server` with zero setup |
| grblHAL simulator via `CNC.Transport.TCP` | Real grblHAL core compiled for Linux/Windows; `grblHAL_sim -p 2323` exposes a raw TCP (telnet) port | Integration tests and dev UI against real Grbl behaviour: planner, acceleration, jog cancel, status reports, alarms, soft limits |

**Notes on grblHAL sim:**
- Build from the grblHAL Web Builder (Driver: Simulator, Board: Linux) or from `github.com/grblHAL/Simulator`.
- Upstream marks it proof-of-concept: pin a known-good build in the Dockerfile.
- Linux/Windows only → run in Docker (Mac) or on a Linux box on the LAN.
- No FluidNC host simulator exists; grblHAL speaks the same Grbl 1.1 protocol, which covers everything Phase 1 uses. FluidNC-specific commands (`$Config/...`) are a later-phase concern on the real board.
- Configure via `$` settings at container start: steps/mm, max rate, accel, travel (`$130/$131` = 1250), soft limits on (`$20=1`), homing on (`$22=1`).

**`CNC.Transport.Sim` behaviour:**
- Boots into `Alarm`; `$X` → `Idle`; `$H` → `Home` then `Idle` at origin.
- `$J=` queues a relative move; position integrates at the given feed (10 ms tick, constant velocity is fine — no accel model needed).
- `0x85` clears queued jogs and stops; `!`/`~` hold/resume.
- `?` replies with a status line encoded by `CNC.Grbl`.
- Soft limits: jog beyond travel → `error:15`.
- Test hooks: latency, dropped acks, `ALARM:N`, disconnect.

---

## 6. Module specs

### CNC.Grbl (pure)
- `Response.parse(line) :: :ok | {:error, code} | {:alarm, code} | {:status, Status.t()} | {:msg, binary} | {:banner, binary} | {:unknown, binary}`
- `Status` struct: `state`, `substate`, `mpos {x,y,z}`, `wco`, `feed`, `spindle`, `buffer`. Derive `wpos` when `wco` known.
- `Status.encode/1` — used by `Transport.Sim`.
- `Command.jog({dx, dy, dz}, feed_mm_min) :: iodata` — omits zero axes, fixed decimals.
- `Command.unlock/0`, `Command.home/0`.
- `Realtime.status/0, feed_hold/0, resume/0, reset/0, jog_cancel/0`.
- Tests: table tests from real grblHAL/FluidNC output samples; StreamData round-trip for jog encoding and status encode/parse.

### CNC.Transport (port + adapters)
```elixir
defmodule CNC.Transport do
  @callback start_link(owner :: pid, opts :: keyword) :: GenServer.on_start()
  @callback write_line(pid, iodata) :: :ok
  @callback write_realtime(pid, byte) :: :ok
  # Adapter sends owner: {:transport, :connected} | {:transport, :line, binary} | {:transport, :disconnected}
end
```
- `CNC.Transport.Sim` — see §5.
- `CNC.Transport.TCP` — `:gen_tcp`, `packet: :line`, `active: :once`. Exits on socket close; supervisor restarts with backoff. Also usable later for FluidNC's Wi-Fi telnet channel.
- Config: `config :cnc, :transport, adapter: CNC.Transport.Sim, opts: []` (dev default); `adapter: CNC.Transport.TCP, opts: [host: ~c"localhost", port: 2323]` via env `CNC_TRANSPORT=grblhal_sim`.

### CNC.Machine (state + jogging)
`gen_statem`, single owner of the Transport process.

States: `:disconnected → :connecting → :alarm | :idle`; `:idle ↔ :jogging`; `:idle → :homing → :idle`; any → `:alarm` on `ALARM:`; any → `:disconnected` on transport loss.

API:
- `status/0` → `%CNC.Machine.State{}` (state, mpos, wpos, connected?, last_error, tier, jog vector)
- `unlock/0`, `home/0`, `feed_hold/0`, `resume/0`, `reset/0`
- `jog/2` (`{dx, dy}` with each in `-1..1`, `tier`) — start or update continuous jog
- `jog_heartbeat/0`, `jog_stop/0`
- `jog_step/2` (`{dx, dy}`, `mm`) — single increment
- PubSub topic `"machine"`: `{:machine, %State{}}` on change, throttled to ≤20/s.

Internals:
- Poll `?` every 200 ms when idle, 50 ms while jogging (smooth visualization).
- Track outstanding lines (sent − acked).
- Reject commands invalid for the current state: `{:error, {:invalid_state, s}}`.

**Jogging (dead-man):**
| Param | Value |
|---|---|
| tick `dt` | 50 ms |
| tiers (mm/s) | fine 5, normal 20, fast 50 |
| increment | `speed × dt`; diagonal vector normalised so path speed = tier speed |
| max outstanding jog lines | 4 |
| heartbeat timeout | 250 ms → `0x85` |
| `jog_stop` | `0x85` immediately |
| step increments | 0.1, 1, 10, 50 mm |

### CNCWeb (UI)
One LiveView, `MachineLive` at `/`.

Layout:
- Header: adapter name (Sim / grblHAL sim), connection badge, state badge, alarm banner with **Unlock** / **Home**.
- **Bed view** (main area).
- Side panel: WPos/MPos readout, tier selector, step buttons, hold/resume/reset, keyboard help.

**Bed view (hook `BedView`, `<canvas>`):**
- Top-down 1250 × 1250 mm bed, scaled to fit, Y up, origin front-left.
- 100 mm grid, travel limits outline, origin marker.
- Tool marker (crosshair + circle) at reported MPos.
- Trail: last ~2000 reported positions as a polyline (ring buffer in JS), fading. "Clear trail" button.
- Commanded jog vector shown as a small arrow on the marker (debug aid: commanded vs. reported).
- State colour on the marker: idle grey, jogging blue, alarm red.
- Data flow: LiveView `push_event("pos", %{x, y, state})` on each status change; hook interpolates between samples with `requestAnimationFrame` for smooth motion at 60 fps. No positions come from the client.

**Keyboard (hook `JogKeys` on `window`):**
| Key | Action |
|---|---|
| ← / → | X− / X+ |
| ↑ / ↓ | Y+ / Y− |
| Shift (held) | fast tier |
| Alt/Option (held) | fine tier |
| Esc | jog stop + feed hold |
| `?` | toggle help |

Hook rules:
- Held-key set → vector; two keys = diagonal.
- Ignore `event.repeat`; ignore when focus is in an input; `preventDefault` on arrows.
- Push `jog` on vector/tier change, `jog_heartbeat` every 50 ms while vector ≠ 0, `jog_stop` when the set empties.
- `blur`, `visibilitychange` (hidden), `pagehide` → clear set + `jog_stop`.

---

## 7. Tooling

- **mise** pins Erlang and Elixir (`.mise.toml`).
- All checks run locally: `mix precommit` = `compile --warnings-as-errors` (Boundary), `deps.unlock --unused`, `format`, `test`.
- `ExUnit.configure(exclude: [:grblhal_sim])`. Run with `GRBLHAL_SIM=localhost:2323 mix test --only grblhal_sim`.
- `docker/grblhal-sim/Dockerfile` builds/pins grblHAL_sim and applies `$` settings on start; `docker compose up grblhal-sim`.
- `docs/bench-log.md` for manual checks.

---

## 8. Milestones (Phase 1)

| # | Milestone | Done when |
|---|---|---|
| M0 | Scaffold `cnc` (no Ecto/mailer/gettext), Boundary compiler, mise | `mix precommit` green; a deliberate cross-boundary call fails compile |
| M1 | `CNC.Grbl` parse + encode | Table tests pass on real status/ok/error/alarm/banner/msg samples; round-trip properties pass |
| M2 | `CNC.Transport.Sim` | Responds to `?`, `$X`, `$H`, `$J=`, `0x85`, `!`, `~`; position integrates; soft-limit `error:15` |
| M3 | `CNC.Machine` + jogging (vs Sim) | Tests: state transitions; ≤4 outstanding jogs; heartbeat loss → `0x85` within 300 ms; `jog_stop` → immediate `0x85`; jog rejected in `:alarm` |
| M4 | `MachineLive` + `JogKeys` + `BedView` (vs Sim) | `mix phx.server`: arrows move the marker live; diagonals; tiers; trail draws; tab blur stops motion; Unlock/Home work |
| M5 | `CNC.Transport.TCP` + grblHAL sim in Docker | `@tag :grblhal_sim` tests pass (connect, `$X`, `$H`, jog + `0x85`, status, soft-limit error); same UI drives grblHAL sim with visible acceleration and stops at travel limits |

**Phase 1 ends at M5.**

### Next phases (not planned in detail)
- **Phase 2 — real board:** `CNC.Transport.UART`, bench motor on the 6x board from the Mac, Z axis (Page Up/Down + side view).
- **Phase 3 — Pi:** `cnc_firmware` Nerves project, `http://cnc.local`, phone jog pad.
- Later: job streaming, toolpath preview + progress, storage, conversational ops, kiosk + HDMI touch, config sync, probing.

---

## 9. Safety rules for the code

- Never send a long jog and rely on a stop message. Short increments + heartbeat only.
- Any disconnect/reconnect/reset → `:disconnected` or `:alarm`; require explicit Unlock/Home.
- The UI renders state from status reports only; it never assumes a command succeeded.
- No e-stop in software. Hardware owns it.

---

## 10. Open questions

- grblHAL sim: pick and pin a build that runs cleanly in Docker; confirm the `-p` TCP mode and settings persistence.
- Does grblHAL sim model acceleration in reported positions realistically enough to judge jog feel? (If not, it still validates protocol behaviour.)
- Status poll rate vs. smoothness: is 50 ms while jogging enough with client-side interpolation?
