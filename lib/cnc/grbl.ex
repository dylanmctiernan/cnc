defmodule CNC.Grbl do
  @moduledoc """
  Pure Grbl 1.1 protocol: response/status parsing, command and real-time
  byte encoding. Shared by grblHAL and FluidNC.
  """
  use Boundary, deps: [], exports: []
end
