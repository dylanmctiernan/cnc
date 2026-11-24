defmodule CNC do
  @moduledoc """
  Domain core: everything about talking to and modelling the machine.

  Sub-boundaries, inner to outer:

    * `CNC.Grbl`    — pure Grbl 1.1 protocol (parse/encode). No processes, no IO.
    * `CNC.Transport`  — transport port + adapters (FakeSim, FluidNCSim, UART, TCP).
    * `CNC.Machine` — the only process that owns a Transport connection; state + jogging.
    * `CNC.GCode`   — pure G-code → toolpath, for previews.
    * `CNC.Program` — the loaded G-code file, shared by every device.

  Only `CNC.Machine` is exported, so callers outside the domain (the web UI)
  cannot reach the protocol or the transport.
  """
  use Boundary, deps: [], exports: [Machine, Machine.State, Settings, Program, GCode.Program]
end
