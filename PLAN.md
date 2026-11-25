# CNC Host — Plan

Learning project: an Elixir host (Phoenix LiveView, later on Nerves / Raspberry Pi 5) that drives a home-built CNC router through a FluidNC controller.

## Phase 1 goal

**Manually move a simulated machine in X/Y with the arrow keys, and watch it move on a live top-down view of the bed.** No hardware required.

- Simulators only: the in-process Elixir Sim, then the real grblHAL firmware simulator over TCP.
- X/Y only. Z is not jogged or displayed in Phase 1 (protocol and state stay 3-axis so Z is a small addition later).
- Out of scope: real board (UART), Z, Nerves/Pi, storage, job streaming, toolpath preview, kiosk, config sync, probing.

---

## 1. Principles

- **Minimal abstractions, explicit seams.** One port, `CNC.Link`, because it has real alternative implementations (Sim, TCP, later UART). No other behaviours until a second implementation exists.
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
        │ CNC.Link port, Grbl 1.1 text protocol
        ├──► CNC.Link.FakeSim  (in-process fake, unit tests + default dev)
        └──► CNC.Link.TCP  ──► grblHAL_sim (real Grbl firmware logic, Docker on Linux)

Later: CNC.Link.UART ──► 6x board (FluidNC) ──► DM542T ──► NEMA 23
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
│   ├── transport/        # boundary CNC.Link — link to the controller (Sim, TCP)
│   └── machine/          # boundary CNC.Machine   — state + jogging
├── lib/cnc.ex            # boundary CNC           — domain root; exports Machine
├── lib/cnc_app.ex        # boundary CNCApp        — supervision + config wiring only
├── lib/cnc_web/          # boundary CNCWeb       — LiveView UI + JS hooks
├── assets/js/hooks/      # JogKeys, BedView
└── test/
```

### Boundaries

| Boundary | deps | exports | Notes |
|---|---|---|---|
| `CNC.Grbl` | — | `Command`, `Response`, `Status`, `Realtime` | Pure functions. No processes, no IO |
| `CNC.Link` | `CNC.Grbl` | `CNC.Link` (behaviour), `Sim`, `TCP` | Port + adapters. Line-level transport |
| `CNC.Machine` | `CNC.Grbl`, `CNC.Link` | `CNC.Machine` (API), `CNC.Machine.State` | Owns the connection. Only process that talks to Transport |
| `CNCWeb` | `CNC.Machine` | — | Must not reference `CNC.Link` or `CNC.Grbl` |
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
| `CNC.Link.FakeSim` (Elixir) | Small in-process fake. Not a faithful firmware | Unit tests of `CNC.Machine`; fault injection; default `mix phx.server` with zero setup |
| grblHAL simulator via `CNC.Link.TCP` | Real grblHAL core compiled for Linux/Windows; `grblHAL_sim -p 2323` exposes a raw TCP (telnet) port | Integration tests and dev UI against real Grbl behaviour: planner, acceleration, jog cancel, status reports, alarms, soft limits |

**Dropped 2026-11-24:** the grblHAL simulator served M5, then went: it leaked a socket per reconnect, served one client at a time and stalled intermittently under our traffic. Real-firmware checks move to an ESP32 dev board flashed with FluidNC (no motors needed; see Phase 2). Kept for the record:

**Notes on grblHAL sim:**
- Build from the grblHAL Web Builder (Driver: Simulator, Board: Linux) or from `github.com/grblHAL/Simulator`.
- Upstream marks it proof-of-concept: pin a known-good build in the Dockerfile.
- Linux/Windows only → run in Docker (Mac) or on a Linux box on the LAN.
- No FluidNC host simulator exists; grblHAL speaks the same Grbl 1.1 protocol, which covers everything Phase 1 uses. FluidNC-specific commands (`$Config/...`) are a later-phase concern on the real board.
- Configure via `$` settings at container start: steps/mm, max rate, accel, travel (`$130/$131` = 1250), soft limits on (`$20=1`), homing on (`$22=1`).

**`CNC.Link.FakeSim` behaviour:**
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
- `Status.encode/1` — used by `Transport.FakeSim`.
- `Command.jog({dx, dy, dz}, feed_mm_min) :: iodata` — omits zero axes, fixed decimals.
- `Command.unlock/0`, `Command.home/0`.
- `Realtime.status/0, feed_hold/0, resume/0, reset/0, jog_cancel/0`.
- Tests: table tests from real grblHAL/FluidNC output samples; StreamData round-trip for jog encoding and status encode/parse.

### CNC.Link (port + adapters)
```elixir
defmodule CNC.Link do
  @callback start_link(owner :: pid, opts :: keyword) :: GenServer.on_start()
  @callback write_line(pid, iodata) :: :ok
  @callback write_realtime(pid, byte) :: :ok
  # Adapter sends owner: {:link, :connected} | {:link, :line, binary} | {:link, :disconnected}
end
```
- `CNC.Link.FakeSim` — see §5.
- `CNC.Link.TCP` — `:gen_tcp`, `packet: :line`, `active: :once`. Exits on socket close; supervisor restarts with backoff. Also usable later for FluidNC's Wi-Fi telnet channel.
- Config: `config :cnc, :link, adapter: CNC.Link.FakeSim, opts: []` (dev default); `adapter: CNC.Link.TCP` via `CNC_LINK=tcp CNC_TCP=<host>[:port]` (FluidNC Wi-Fi telnet, port 23); `CNC.Link.UART` via `CNC_LINK=uart CNC_UART=<device>`.

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
- `docs/bench-log.md` for manual checks.

---

## 8. Milestones (Phase 1)

| # | Milestone | Done when |
|---|---|---|
| M0 | Scaffold `cnc` (no Ecto/mailer/gettext), Boundary compiler, mise | `mix precommit` green; a deliberate cross-boundary call fails compile |
| M1 | `CNC.Grbl` parse + encode | Table tests pass on real status/ok/error/alarm/banner/msg samples; round-trip properties pass |
| M2 | `CNC.Link.FakeSim` | Responds to `?`, `$X`, `$H`, `$J=`, `0x85`, `!`, `~`; position integrates; soft-limit `error:15` |
| M3 | `CNC.Machine` + jogging (vs Sim) | Tests: state transitions; ≤4 outstanding jogs; heartbeat loss → `0x85` within 300 ms; `jog_stop` → immediate `0x85`; jog rejected in `:alarm` |
| M4 | `MachineLive` + `JogKeys` + `BedView` (vs Sim) | `mix phx.server`: arrows move the marker live; diagonals; tiers; trail draws; tab blur stops motion; Unlock/Home work |
| M5 | `CNC.Link.TCP` + grblHAL sim in Docker | `@tag :grblhal_sim` tests pass (connect, `$X`, `$H`, jog + `0x85`, status, soft-limit error); same UI drives grblHAL sim with visible acceleration and stops at travel limits |

**Phase 1 ends at M5.** Status (2026-11-23): M0–M4 done. M5 done except `$H` and the soft-limit error, which the grblHAL simulator can't do (no limit-switch simulation, so no homing, so no soft limits); those move to Phase 2 on the real board. Travel limits against grblHAL are enforced by the host clamp. See §11.

### Next phases (not planned in detail)
- **Phase 2 — real board:** First a bare ESP32 dev board flashed with FluidNC, no motors: real firmware, planner and USB serial on the desk. Then `CNC.Link.UART`, bench motor on the 6x board from the Mac, Z axis (Page Up/Down + side view). Carries over from M5: homing and soft-limit tests. See §11 for what to verify on FluidNC. **Settings from the app:** a `CNC.Settings` boundary to read the controller's configuration (grblHAL `$$`; FluidNC `$CD` / `config.yaml`) and edit it with names, units and ranges, showing a diff and confirming before writing, only when Idle/Locked, then re-reading to verify.
- **Phase 3 — Pi:** `cnc_firmware` Nerves project, `http://cnc.local`, phone jog pad.
- Later: job streaming, toolpath preview + progress, storage, conversational ops, kiosk + HDMI touch, config sync, probing.

---

## 9. Safety rules for the code

- Never send a long jog and rely on a stop message. Short increments + heartbeat only.
- Any disconnect/reconnect/reset → `:disconnected` or `:alarm`; require explicit Unlock/Home.
- The UI renders state from status reports only; it never assumes a command succeeded.
- No e-stop in software. Hardware owns it.
- Bound queued motion by distance, not just acks: at most 4 jog increments ahead of the last *reported* position (controllers ack on planning; grblHAL's planner is 100 blocks deep).
- The host clamps jogs and steps to travel. The configured travel is the physical maximum: the controller may narrow it, never widen it.
- Esc always stops (jog cancel + feed hold), even while typing in the console.
- A link that looks open but has gone silent is dead: no status for 1.5 s (6 s while connecting, none while homing) → jog cancel, close, reconnect, re-lock.
- Typed console commands are allowed only when Ready/Locked/Busy and are labelled as bypassing the jog dead-man and the travel clamp.
- LAN only, one user, no login. Only local names and addresses are served (`CNCWeb.AllowedHost`) and only the app's own pages may open its socket (`check_origin: :conn`), so no website can drive the machine through a browser. Never port-forward.

---

## 10. Open questions

Answered in Phase 1 (details in `docs/bench-log.md`):

- ~~grblHAL sim build~~ Pinned at `9d1a390`, built on Debian trixie (needs glibc ≥ 2.38). `-p 2323` works; settings persist in `/data/EEPROM.DAT`, so they're baked into the image at build time (the newest TCP client takes over the stream, which rules out configuring at runtime).
- ~~Acceleration realism~~ Yes: jog cancel visibly decelerates, and the planner and buffers behave like firmware. It can't home or enforce soft limits.
- ~~50 ms polling~~ Smooth enough with client-side interpolation, by eye on the Sim and grblHAL.

Answered against FluidNC (sim and source, commit `97dfddc`), to confirm on the board (`docs/bench-esp32.md`):

- ~~Does FluidNC's `$$` report `$130`–`$132`?~~ Yes: from each axis's `max_travel_mm`.
- ~~Does homing leave machine coordinates 0..travel?~~ It does if configured so: homing toward the negative end with `mpos_mm: 0` gives 0..`max_travel_mm`, toward the positive end −`max_travel_mm`..0 (`Limit.cpp`). The position is set after the final pull-off, so homed is exactly 0 and the switch sits `pulloff_mm` outside travel. Our configs home X/Y negative and Z up.
- ~~Are lines received but not yet acked discarded by `0x85`?~~ **No.** FluidNC acts on a jog cancel only if it's already in Jog, and the cancel flushes the planner, not lines still waiting to be parsed. A quick tap can send lines, then a cancel that arrives before the first one starts: the cancel is ignored and the lines run. Machine now "cancels until quiet": after a stop, any jog ack or Jog report gets another `0x85`, until the controller is Idle with nothing unacked. (The native sim can't show this: its console drops bytes ≥ 0x80, so `0x85` never reaches it. A FluidNC bug in the posix console only.)

Open for the board:

- Does opening the USB serial port reset the ESP32 (DTR/RTS)? It would show as a banner and re-lock, which is safe but should be known.
- After an `ALARM:N`, are unacked lines dropped (no acks will come)? Machine assumes so and forgets them.
- Does jog cancel stop promptly on the board (the sim can't test `0x85`)?

---

## 11. Phase 1 outcome: changes from this plan

- **`CNC.Motion` → `CNC.Link`.** It's the link to the controller; `CNC.Machine` holds the conversation.
- **`CNC.Application` → `CNCApp`**, a top-level wiring boundary beside `CNC` and `CNCWeb` (as Boundary recommends).
- **Jog safety:** added the distance-ahead bound and the host travel clamp (§9).
- **Travel from the controller:** Machine reads `$130`–`$132` via `$$` after every connect; config travel is the physical maximum.
- **Controller details and console:** raw traffic both ways (status polls opt-in), controller facts, a terminal (`Machine.send_raw/2`) and a command reference.
- **LAN access** (`CNC_LAN=1`; the PIN it first needed was removed, see below).
- **No CI:** all checks run locally via `mix precommit`.
- **grblHAL simulator dropped (2026-11-24).** Dev and tests use the built-in Sim (now FakeSim); real-firmware checks use an ESP32 dev board running FluidNC. `CNC.Link.TCP` stays for FluidNC over Wi-Fi.
- **Native FluidNC is the dev controller (2026-11-24).** FluidNC builds as a Mac/Linux program (`env:macos`/`env:linux`): stock firmware at a pinned commit (`mix cnc.fluidnc.build`), run by `CNC.Link.FluidNCSim` (renamed from NativeFluidNC) over stdin/stdout. Config per board: `priv/fluidnc/sim.yaml` (dev: `engine: timed`, no switches) and `priv/fluidnc/esp32_bench.yaml`. Telnet/HTTP are switched off through its settings store before start; an `sh` watchdog stops it if the app dies. Soak: 225 held jogs, 0 gaps, 0 errors. It answers §10's first question: FluidNC's `$$` does report `$130`–`$132`. No switches, so homing is set-position-only (`$22=0`): Unlock.

---

## 12. Backlog and ideas

Not scheduled; kept so they aren't lost.

- **Controller config from the app.** FluidNC's `$110`/`$130`-style settings are read-only proxies (`error:162`); its machine config is `config.yaml`. Running values change with `$/axes/x/max_rate_mm_per_min=2000` (immediate, in memory, validated by FluidNC) and persist with `$CD=config.yaml` (rewrites the file; comments are lost). Whole files go over serial with `$Xmodem/Receive`, then `$Bye` restarts. The Settings page writes Grbl `$` settings today, so on FluidNC its writes are refused: it needs a FluidNC mode. **Decided (2026-11-24): the controller is the source of truth**; the app keeps a timestamped history of every config it has seen or sent (for diff and restore), and `priv/fluidnc/*.yaml` are starting templates. Proposed flow: tuning = edit, review diff, apply live (`$/path=value`), test, save (`$CD=config.yaml`, after backing up the current file); structural changes = edit YAML, boot-check it in the FluidNC sim, diff against the controller, send (XModem), restart, verify a clean boot, one-click restore otherwise. Only when Ready or Locked.
- **Upstream FluidNC fixes** (both in `FluidNC/posix/Console.cpp`, native build only): exit on stdin EOF (would retire the `sh` watchdog in `CNC.Link.FluidNCSim`); read bytes as unsigned (so `0x85` jog cancel reaches the sim and it can test cancel).
- **Jobs, later** (decided 2026-11-24: wanted, but UX-heavy, so after the basics). A job is an ordered list of steps (cut a file, bit change with Z re-zero, operator steps like flip or load the next stock); a queue is jobs in order, e.g. two pieces. Bit changes come from the CAM (`M6 T2` in one file, or one file per bit) and are handled the same way: pause, prompt, re-zero Z (probe or tool setter on a 6x input), resume. Keep this possible: a job runner beside `Machine` (which stays the only process talking to the controller), jobs as step lists from the start. The 6x board has a micro SD socket, so long jobs could run from the controller (`$SD/Run`) with the host watching.
- **Now: upload a G-code file and see its cut map** (2D toolpath on the bed view, with size, fit-in-travel check and warnings). No running yet. CAM still undecided (Carbide Create or Fusion).
- **Speed meter units:** mm/min (matches G-code and the header) vs mm/s (matches the tier definitions, shorter numbers).
- ~~Intermittent LiveView jog test failures~~ Fixed (2026-11-24): screen tests each run their own Machine and program store (`CNCWeb.Instance`, honoured only in tests), and run in parallel; MachineTest and the FluidNC sim tests are split by area. Suite ~21 s → ~9.5 s.
- **Controllers, boards and links (2026-11-24, stage 1 of the config work).** `CNC.Transport` → `CNC.Link`. `CNC.Boards`: the catalogue (FluidNC sim, ESP32 DevKit, 6x from FluidNC's contributed `6x_default.yaml`) and one config template, `priv/fluidnc/config.yaml.eex` (the machine, written once) filled with each board's pins. `CNC.Controllers`: profiles (a board + a link; the config lives on the controller), stored in `<data_dir>/controllers.json`, one active, which `Machine.connect/2` switches to. A FluidNC sim keeps its own config in `.cnc/controllers/<id>/fluidnc/` across restarts. `CNC_LINK` overrides the profiles. Stage 2 (same day): `/controllers` page (from the header's controller status, the menu, Settings): list, use (refused while moving), change link (only the board's links, `CNC.Boards.links/1`), add, remove. Next: the config workflow (stage 3).
- **Embedded storage: CubDB (2026-11-24).** The app's own data lives in one CubDB at `<data_dir>/db` (`.cnc/db` in dev, `/data/db` on the Pi): pure Elixir, synced on every write, the Nerves community's usual choice. Chosen over SQLite/Ecto for simplicity and Nerves fit. Note: CubDB 2.0.2 (Jan 2025) is stable but quiet, and compiles with deprecation warnings on Elixir 1.20 (pin operator in binary size); watch it on Elixir upgrades. Controller profiles moved there from `controllers.json` (imported once). The list starts empty; FluidNC sims (and the fake sim) can be forked: an independent copy of the sim's folder. Boards aren't forkable: one board holds one config (experiment with config versions instead). Removing a FluidNC sim deletes its folder.
- **Config work, stage 3a (2026-11-24): `/controllers/:id/configuration`** (from each controller card). A controller can hold several config files; this page lists them (which one loads at start), shows one, saves the running config as a new file (`$CD=<name>`: FluidNC has no copy, and the dump includes every default, so copies are about twice the size), switches (`$Config/Filename=` only for a file that's there, since FluidNC doesn't check, then `$Bye`; the controller restarts and comes back locked) and deletes (not the loaded one). Built on `Machine.request/3` (a command's whole reply up to its ok/error; answered `{:error, :reset}` if the link drops). The fake sim speaks these commands. Configuration is separate from setting up a controller (board + link). Next (3b): edit settings live (`$/axes/x/...=v`), diff running vs file, save; snapshots in CubDB for history. `CNC.Settings` (Grbl `$N`) is to be retired in favour of `Controllers.Config`; "settings" is kept for the app's own settings.
- **Config work, stage 3b (2026-11-24):** on the configuration page, change settings live: a per-axis table (steps/mm, max rate, acceleration, max travel) and any setting by path (`$/path=value`, then read back: FluidNC answers `ok` even for a bad number or a setting it can't change while running). "Not saved yet" comes from the board: the running config (`$CD`) against the file it loaded (values compared as numbers, YAML quotes ignored), so console changes show too. The app's own record covers settings the file leaves out (defaults). Undo, or Save into the loaded file (`$CD=<file>`; the old text goes into the history in CubDB, max 30 per controller, also before a delete). The Settings page (Grbl `$N`) is gone. Next: restore an earlier version (needs uploading a file: XModem), and the header shows the link instead of a Simulator badge.
- **Config work, stage 4 (2026-11-24): boards own wiring; writing files to the controller.** `Boards.wiring?/1` (pins, stepping, buses) keeps wiring out of live edits, and the page checks the controller's wiring against its board's pin map. `Machine.upload/4` puts a file on the controller: XModem-1K/CRC over USB or Wi-Fi (state `:uploading`, polling and watchdog paused; telnet's 0xFF doubled), or straight into the sim's folder (its console can't carry bytes >= 0x80). On top: Restore an earlier version, Write board default, Restart to reload. XModem is tested against a scripted receiver only; the bench session checks it on the board (bench doc check 11).
- **Profiles (2026-11-24), replacing file-based config.** A profile is a named set of a controller's editable settings (everything but wiring), kept in the app (CubDB, per controller) with the one selected. The controller holds one file, `config.yaml`, rendered from board + selected profile (`Profiles.render/2`: the board's default config as a YAML tree with the profile's values set; `CNC.Controllers.Yaml`). Switching writes that file and restarts. Editing a value applies it live (read back), stores it and rewrites the file. The file is read back and checked against the selected profile: matches, differs (write the profile and restart, or keep the file's values), or another file loaded directly (override). Live values changed elsewhere show as drift (keep or put back). Every earlier version of the file is in the app's history (restore under Advanced). First contact makes "Default" from what the controller runs, writing nothing. The Controllers page shows each controller's profile and whether its file matches.
- **Configuration page layout (2026-11-24).** Current settings on top: the selected profile read-only (axis table; View shows every setting), Edit to change it live, Rename; the check against the controller's file (matches; differs, listing conflicts and how many settings the file leaves to FluidNC's defaults, with Write the profile and restart / Keep the controller's values; or another file loaded); live values that differ (only when the file matches). Other profiles below: Switch to this, View, Edit (stored in the profile, checked by the app: no wiring, numbers stay numbers; applied when switched to), Rename, Delete; New profile. Advanced is the escape hatch: view config.yaml, upload a config file of your own (it becomes config.yaml and the controller restarts), earlier versions (restoring config.yaml restarts with it). The check compares the file with what the profile would write (board defaults + profile), so a file the app didn't write differs until a profile is written.
- **Approvals, overrides, histories (2026-11-24).** Every change is shown as a diff in a dialog first (switch, apply, save another profile, write the profile, keep the controller's values, keep/put back running values, an override, a restore); nothing happens until Approve. Overrides: your own config, uploaded or pasted (Advanced), replaces config.yaml (wiring included). Two histories, each a version per change with its reason and diff: the controller's config (every write, with the file as written; live-only changes too) and each profile's (made, edited, changed live, kept from the controller, renamed, restored, with the values after). Restoring a version is itself a new version ("Restored v4"). Diffs list changed values first and fold settings only one side has (one file spells out what the other leaves to FluidNC's defaults).
- **Configuration restructured (2026-11-24).** "Configuration" is everything about machining; "settings" is reserved for the app's own preferences. `CNC.Configuration` (its own boundary, after Controllers, which is back to devices: board + link) coordinates three parts, each versioned: the machine's **build** (steps/mm, travel, homing geometry, hard limits; one, carries over to another controller), each controller's **wiring** (pins, stepping, buses; seeded from what it runs, unconnected pins left out) and the machine's **profiles** (how it's run; also carry over). A controller's config.yaml = its wiring + the build + the selected profile, nothing merged from templates. Changes go to their part: build and profile values live, wiring after a restart (said in the approval dialog). Modules: Configuration (coordinator), .Build, .Wiring, .Profiles (store), .FluidNC (firmware: files, $CD, $/path, upload, restart), .History (writes to a controller's config), .Values (parse, diff, compare), .Layer, .Yaml. Old per-controller profiles migrate to the machine on first contact.
- **App settings: `CNCApp.Settings` (decided 2026-11-24, not built).** The app's own preferences (LAN access, units, mDNS name; later jog defaults, theme) live in the `CNCApp` boundary, stored in the app's CubDB; screens read them. Not under `CNC` (that's machining: "configuration") nor a boundary of their own. Environment variables (`CNC_LAN`) stay as overrides, like `CNC_LINK`, with stored settings as the normal source.
- **Configuration page in tabs, with one changeset (2026-11-24).** /configuration has a status strip (controller, profile, in step or not) and tabs with their own URLs: Profiles, Build, Wiring, File, History. Editing a value anywhere stages it into one changeset (`CNC.Configuration.Changes`, in the app's database so every screen shares it); tabs show how many are staged; a sticky bar offers Discard or Review & apply; the review groups the diff by part, lets you remove single changes, flags ones changed elsewhere since (stale) and says whether the controller restarts; `Configuration.apply/4` applies them together (one file write, one history version; another profile's are stored only). "Apply now" stages and reviews just those edits. Switching profile, overrides and restores keep their own diff dialogs.
- **Design overhaul, stages 1-3 (2026-11-24).** Tokens in three tiers (app.css: reference palette, semantic names, sizes) with IBM Plex Sans for the interface and Plex Mono for numbers/paths/code. Component kit `CNCWeb.UI` (aliased as `UI` in every template: page_header, section, card, button, tabs, pill, machine_state, stop_button, dialog, empty), styled by `ui-*` classes on tokens only. **The standard for every page from now on: build from the kit, no one-off CSS.** The workstation shell (`Layouts.app`): a left rail (Machine, Configuration, Controllers; Pendant, the machine state and Stop pinned at its foot), collapsible to icons; on narrow screens a top bar (state and Stop) with the rail as a drawer. `CNCWeb.Shell` (on_mount) keeps the rail's machine state and handles its Stop; pages in the shell don't subscribe to the machine themselves. Configuration and Controllers use the kit's header, tabs, buttons and dialogs; the machine screen sits in the shell as it was (its own restyle comes with the 3D viewport). Next: the pendant (`/pendant`, joystick jogging + state + Stop, for phone and tablet), then the 3D viewport, then finishing the pages' inner pieces on the kit.
- **Design overhaul, stages 4-6 (2026-11-24).** The pendant (`/pendant`, its own surface for phones and tablets: state, position and a large Stop on top; jog speed; a big X/Y stick and Z slider on the shared Joystick hook; Unlock when locked; more pendant functions as needed: zeroing, a handwheel, feed hold). The 3D viewport as a standard component: `<UI.viewport>` + the `Viewport` hook (three.js 0.187 from npm, bundled into app.js; `assets.setup` runs npm install), machine coordinates with Z up: bed and grid, travel envelope, work-zero axes, toolpath (cuts solid, rapids faint), the tool; orbit/pan/zoom; File/Iso/Top/Front views; renders only on change; colours from the tokens. Machine views share one event API ("pos", "program", "travel"; "viewport_ready" asks for the current state). The machine screen switches its bed view between 2D and 3D. Still to do: the machine screen's own restyle on the kit (its header and panels), and the remaining inner pieces of the configuration and controllers pages (cards, forms) onto the kit; trimming the three.js import if the bundle size matters on the Pi.

- **Hold, not Stop (2026-11-24).** What the app called Stop was a feed hold (jog cancel + `!`): motion pauses on its path, the position and the job are kept, the spindle keeps turning (Grbl/FluidNC), Resume (`~`, cycle start) carries on. Calling it Stop suggested the job was over and the machine safe. Now one red **Hold** everywhere (the separate Hold button merged into it; Esc too), **Resume** beside it, enabled only when there's a hold to release, and **Reset** (abandon the job) quiet and apart. Not an e-stop: that's hardware on the machine. When jobs and the spindle come in: decide whether Hold also stops the spindle, or warn that it's still turning while held.
- **Desktop workstation, mobile pendant; no layout shift (2026-11-24).** The workstation (machine, configuration, controllers) is for desktop screens, at least 1024 × 600 (a tablet sideways counts); the mobile-first machine layouts (touch controller, Hold dock, More menu, Zero tab) and the shell's phone top bar are gone. Below that size the shell shows "too small", points to the pendant and keeps the state and Hold in reach; "Use anyway" for the session. Under 1280 px the rail is icons only. Layout shifts are treated as bugs: disabled not removed, fixed-size labels, transient things overlay; `mix e2e.layout` (Playwright, assets/e2e/layout_shift.mjs) drives the screens through their interactions against the dev server and fails on any landmark moving. Known, deliberate: opening the console docks it and resizes the map.
- **PIN removed; LAN only, one user (2026-11-24).** The shared 4-digit PIN gave false confidence: it could be guessed in about a minute, was logged in plaintext, and its cookie could be forged with the committed dev secret. The app runs only on the home network for its owner, never reachable from outside. The real protections: only local names and addresses are served (`CNCWeb.AllowedHost`, checked before the sockets too, which stops DNS rebinding); only the app's own pages may open its sockets (`check_origin: :conn`); no dev log streaming to browsers (`web_console_logger` off); FluidNC firmware built USB-only (no Wi-Fi or Bluetooth radio); guests on a separate Wi-Fi; never port-forward. The Lock screen items went with it.
- **Running jobs, first version (2026-11-24).** Streaming over USB from the app (the norm for a wired host; running from the board's storage could be a later mode). The machine's state machine gains `:running` (idle → running → idle; Abort, alarm or a lost link end it; Hold/Resume inside it), `CNC.Machine.Job` streams by character counting (≤127 bytes unacked). The machine screen's cycle-start button is Start (Ready, a file loaded) or Resume (on hold), same place and size; Start opens a pre-start check (fits from the work zero, which bit, clamp/spindle/hands) that refuses a file that won't fit; while running a job panel shows progress, line, elapsed and time left, feed override (−10/100/+10%) and Abort (asks first; a soft reset, comes back locked). The message line carries the on-hold reminder (the spindle keeps turning) and how the job ended. The 2D and 3D views fade what's been cut, following the tool along the path. Tested on the fake sim (now runs G-code) and on real FluidNC. Next: a job log/library, dry run (Z lifted), resume from a line, tool changes, spindle control.
- **Proving a program, the standard way (2026-11-24).** The first-article routine from industrial controls (Haas/Fanuc): preview → check (machine lock / Grbl `$C`) → outline on the stock → dry run (Z lifted, rapids slowed) → first part in single block at reduced rapids → full speed. In the app: a run's mode is data on the job (`:run | :check`, later dry run, single block, rapid override), fixed when it starts, inside the one `:running` state. Done: **Check** ("Check first" in the pre-start dialog): the controller's check mode reads every line without moving; refused lines are collected, not fatal; leaving check mode restarts the controller (FluidNC and Grbl both do), so it ends locked and the Locked banner says how the check went. Next: Outline, rapid override, dry run, single block. **Then piece awareness**: the stock's size and thickness and where its origin is (matching the CAM setup), so the checks are against the stock (fits in it; doesn't cut deeper than it's thick), Outline traces it, and 3D shows it. Before tool changes.
- **App settings begin (2026-11-24).** `CNCApp.Settings`: its own small top-level boundary (the web layer depends on it; `CNCApp`, the wiring, depends on the web layer, so settings can't live inside it), stored in CubDB under `:app_settings`, typed with defaults, unknown keys and wrong types refused, changes broadcast so every open screen follows. A Settings page (gear in the rail, above Pendant), applied at once with nothing to save. First setting: the tool's trail on the 2D map, off by default. What a running job has cut is drawn in a muted green (cuts only; rapids keep their dashed look).
- **The operator panel's modes (2026-11-24).** As a Fanuc/Haas mode selector, under the always-visible readout: **Jog** (continuous: stick, arrow keys), **Inc** (incremental: a step a press), **Auto** (the program: open/drop, Start…, the running job), **MDI** (manual data input: the command line and the controller's replies). One fixed height; loading a file or starting a job switches to Auto; Jog, Inc and MDI say when they're off during a job. The header is the cycle group (Reset, which reads Abort during a job and asks first; Cycle Start/Resume; Hold) plus a **Diagnostics** toggle: the full controller traffic, view only, docked under the map. Open file lives in Auto.
- **The pendant, rebuilt (2026-11-25).** A handheld pendant's job, on a phone at the machine: fixed top (state, work position, the cycle button doing what Cycle Start does now: Start/Resume/Unlock/Next line, and Hold), then Jog · Inc · Zero · Job. Zero has Undo; Job starts after the same fit check, and steers a running job (feed, rapids, single block, Abort). A job started anywhere shows Job. No MDI or file loading (the workstation's). Its own manifest (`/pendant.webmanifest`, start_url `/pendant`): iPhone Add to Home Screen opens it full screen over HTTP; Android installs properly (and the screen can be kept awake) once there's HTTPS on the Pi. `CNCWeb.Run` holds the fit/progress/time helpers both screens use.
- **Time and progress, from the machine (2026-11-25).** The estimate plans the file the way the controller's planner moves it (`CNC.GCode.Timing`): feeds and the axes' max rates, accelerations ($120-122) and junction deviation ($11), corners, start/stop, dwells; each line's time split into feed, rapid and ramps so the feed and rapid overrides scale their own part. Progress is time done, not lines: which line is being cut comes from the tool's reported position on the lines that can be running (bounded below by the planner's waiting blocks, arcs counted as FluidNC splits them, $12), and how far along it; ties between lines sharing a point go to the one nearest the time actually run. The lead-in (from where the tool was at Start to the first move) is timed at Start. Time left leaves out time on hold, door open or waiting for Next line, and blends in the actual pace as the job goes. Against the FluidNC sim: within ~1 s of the truth throughout (`test/cnc/fluidnc_sim_timing_test.exs`). The stock native sim couldn't receive bytes >= 0x80 (its console read signed chars), so overrides and jog cancel never reached it; `mix cnc.fluidnc.build` now applies `priv/fluidnc/patches/sim-console-unsigned.patch` (sim-only I/O; the board's flash stays stock). FluidNC itself passes 0x80-0xBE through raw (`PASS_THROUGH_80_BF`), so the board takes them. Worth reporting upstream.
- **Piece awareness, first step: the stock (2026-11-25).** `CNCApp.Stock`: width × depth × thickness and where the work zero is on it (top, front-left corner or centre), optional, kept in the app's DB and heard by every screen. Set from Auto (Stock … Set/Change). Before Start (workstation and pendant), the file's cuts are checked against it: past an edge, or deeper than it's thick; warnings in amber with the amounts, not refusals (outside profiles and cut-outs do both on purpose). Drawn in 2D (wood-toned fill under the path) and 3D (translucent block in the work group). 
- **Sandbox server.** `CNC_DATA_DIR` gives a second dev server its own data (`PORT=4100 CNC_DATA_DIR=... mix phx.server`): scripts and `mix e2e.layout` (BASE_URL) drive that, never the one in use; the guard refuses to start while a job runs.
- **The bit (2026-11-25).** `CNCApp.Bit`: diameter and kind (flat end mill, ball nose, V-bit with its angle), optional, kept and heard like the stock. With one, the stock's edge checks use where the cutter reaches (path + radius: "The bit reaches 3.2 mm past the stock's right edge: keep clamps clear"); the start checks name it; the 3D tool is drawn as it is (cylinder, rounded tip, or a cone at its angle). Set from Auto (Bit … Set/Change).
- **Touch off and Trace the stock (2026-11-25).** Inc (workstation and pendant): step the bit onto an edge from outside, then "On the left/right edge" (X) or "front/back" (Y); Z's row zeroes on the surface. `CNCWeb.TouchOff`: the bit's radius allowed for; corner-zero stock takes the near edge (or a width back from the far one); centre-zero stock half a size in, or midway once both edges are touched (the radius cancels; the measured size is reported against the stock's). Without a stock only the near edges. The message line says what it did, with Undo. Trace (stock row; pendant Zero) goes round the stock's outline at a safe height, to see a clamp in the way.
- **Long term: sensing (not yet).** Computer vision (a camera over the bed: find the stock and its edges, check for clamps) or laser sensors (edge finding, surface height). Touch-off, Trace and the stock model are the manual versions of what they'd automate; the stock/bit/zero model is where their readings would go.
