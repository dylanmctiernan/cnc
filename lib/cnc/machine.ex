defmodule CNC.Machine do
  @moduledoc """
  Machine state and jogging. Single owner of the `CNC.Transport` process; the
  public API for everything above the domain.
  """
  use Boundary, deps: [CNC.Grbl, CNC.Transport], exports: []
end
