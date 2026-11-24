# Bench log

Manual checks that aren't covered by automated tests. Newest first.

## 2026-11-23 — Status watchdog, grblHAL EEPROM

- Took over the grblHAL sim's TCP stream from a probe while the dev server
  was connected: Machine logged "no status from the controller", dropped the
  link and reconnected on its own (before: it stayed "connected", silent).
- Watchdog test found that killing the transport right after queueing the
  jog cancel lost the byte; transports now `close/1` after flushing.
- grblHAL sim writes settings to EEPROM lazily: the last baked setting
  ($132) was lost when the build stopped the sim immediately. The sim also
  ignores SIGTERM once idle without a client. configure.sh now waits while
  connected, stops with a SIGKILL fallback, and verifies every setting
  after a restart.

## 2026-11-23 — M5: grblHAL simulator findings (commit 9d1a390)

Probed over raw TCP before writing the adapter:

- No banner on connect; boots Idle with homing off. Status carries extra fields
  (`Ov`, `A:`, `Sc:`, `TLR:`, `H:`), ignored by our parser.
- Stock defaults: 200 mm travel, 500 mm/min max rate, 10 mm/s² accel.
- Planner is 100 blocks deep (`Bf:100,1023`): ack-based limits alone would let
  ~100 jog increments queue. The run-ahead bound is what keeps it short.
- `0x85` decelerates (not an instant stop) and flushes all queued jog lines:
  six acked 20 mm jogs stopped at 3 mm and stayed Idle.
- **Homing cannot complete**: limit-switch simulation is an upstream TODO
  (commented out in `simulator.c`); `$H` seeks forever and status polls go
  unanswered meanwhile. Soft reset during homing → `ALARM:6`, blank line,
  `GrblHAL 1.1f ...` banner — same shape our Sim emits.
- **No soft limits**: `$20=1` needs homing (`error:10`); with homing enabled but
  not homed, out-of-travel jogs are accepted (machine space ran negative).
  Against this sim the host clamp is the only travel limit.
- First command on a fresh EEPROM returns `error:7` (defaults restored).
- The newest TCP client silently takes over the stream; settings are therefore
  baked into the image at build time instead of applied at runtime.
- Needs glibc ≥ 2.38 (`strlcpy`): built on Debian trixie. The validator target
  doesn't link at this commit; only `grblHAL_sim` is built.

`mix test --only grblhal_sim`: connect/lock/travel, jog + stop with
deceleration, heartbeat loss stops the firmware, exact step, soft reset relock.
5/5, three runs.

## 2026-11-23 — M4: manual UI checklist (pending)

Run `mix phx.server`, open http://localhost:4000, then check:

- [ ] Locked banner on load; Unlock → Ready; Home → Homing → Ready at 0,0
- [ ] Arrows move the marker live; two arrows = diagonal at the same speed
- [ ] Shift = fast, Option = fine; speed buttons change the default
- [ ] Trail draws and fades; Clear trail empties it
- [ ] Holding into an edge slides to it and stops, no error
- [ ] Switching tab / window while holding a key stops motion
- [ ] ⌘ while holding an arrow stops motion
- [ ] Esc stops and holds; step pad moves by the chosen step

## 2026-11-23 — M3: jog safety test sensitivity

- Removed the in-flight cap, the run-ahead bound, and the dead-man (one at a time):
  each made exactly its own test fail. Reverted; 88 pass.
- Machine tests 5× and full suite 3× in a row without flakes.

## 2026-11-23 — M2: Sim test sensitivity

- Disabled soft-limit check → 2 tests fail. Dropped leftover-time carry between queued jogs → 1 fails.
- Process tests run 3× in a row without flakes. Reverted; 68 pass.

## 2026-11-23 — M1: test sensitivity

- Mutated `Status.derive` (wpos = mpos + wco) and `Command.jog` zero-axis check (never zero).
- 6 tests failed, including both properties and the doctest. Reverted; 45 pass.

## 2026-11-23 — M0: Boundary enforcement

- Added a temporary call `CNCWeb -> CNC.Motion` and `CNC.Grbl -> CNC.Motion`.
- `mix compile --warnings-as-errors` reported `forbidden reference to CNC.Motion` for both and exited 1.
- Reverted; clean compile exits 0.
