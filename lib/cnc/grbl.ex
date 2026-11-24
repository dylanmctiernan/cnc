defmodule CNC.Grbl do
  @moduledoc """
  Pure Grbl 1.1 protocol: response/status parsing, command and real-time
  byte encoding. Shared by grblHAL and FluidNC.

  Lines are handled without their trailing newline; the link
  (`CNC.Link`) owns framing.
  """
  use Boundary, deps: [], exports: [Command, Response, Status, Realtime, XModem]
end
