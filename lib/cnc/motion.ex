defmodule CNC.Motion do
  @moduledoc """
  Transport port: line-level link to a Grbl-speaking controller.

  Adapters (`CNC.Motion.Sim`, `CNC.Motion.TCP`, later `CNC.Motion.UART`)
  send their owner:

    * `{:motion, :connected}`
    * `{:motion, :line, binary}`
    * `{:motion, :disconnected}`
  """
  use Boundary, deps: [CNC.Grbl], exports: [Sim]

  @callback start_link(owner :: pid, opts :: keyword) :: GenServer.on_start()
  @callback write_line(pid, iodata) :: :ok
  @callback write_realtime(pid, byte) :: :ok
end
