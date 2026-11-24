# Bench log

Manual checks that aren't covered by automated tests. Newest first.

## 2026-11-23 — M1: test sensitivity

- Mutated `Status.derive` (wpos = mpos + wco) and `Command.jog` zero-axis check (never zero).
- 6 tests failed, including both properties and the doctest. Reverted; 45 pass.

## 2026-11-23 — M0: Boundary enforcement

- Added a temporary call `CNCWeb -> CNC.Motion` and `CNC.Grbl -> CNC.Motion`.
- `mix compile --warnings-as-errors` reported `forbidden reference to CNC.Motion` for both and exited 1.
- Reverted; clean compile exits 0.
