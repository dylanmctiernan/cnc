defmodule CNC.Machine do
  @moduledoc """
  Machine state and jogging. Single owner of the `CNC.Motion` process; the
  public API for everything above the domain.
  """
  use Boundary, deps: [CNC.Grbl, CNC.Motion], exports: []
end
