# Bench log

Manual checks that aren't covered by automated tests. Newest first.

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
