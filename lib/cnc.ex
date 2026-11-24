defmodule CNC do
  @moduledoc """
  Domain core: everything about talking to and modelling the machine.

  Sub-boundaries, inner to outer:

    * `CNC.Grbl`    — pure Grbl 1.1 protocol (parse/encode). No processes, no IO.
    * `CNC.Link`  — links to the controller: port + adapters (FakeSim, FluidNCSim, UART, TCP).
    * `CNC.Machine` — the only process that owns a link to the controller; state + jogging.
    * `CNC.GCode`   — pure G-code → toolpath, for previews.
    * `CNC.Program` — the loaded G-code file, shared by every device.
    * `CNC.Boards`      — the catalogue of boards (hardware types) and their
      defaults, including the config template. Pure data.
    * `CNC.Controllers` — your controllers (each a board + a link, the
      config on the controller) and which one the machine is using.

  Only `CNC.Machine` is exported, so callers outside the domain (the web UI)
  cannot reach the protocol or the link.
  """
  use Boundary,
    deps: [],
    exports: [
      Machine,
      Machine.State,
      Settings,
      Program,
      GCode.Program,
      Controllers,
      Controllers.Controller,
      Boards
    ]
end
