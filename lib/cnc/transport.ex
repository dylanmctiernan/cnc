defmodule CNC.Transport do
  @moduledoc """
  Transport port: line-level link to a Grbl-speaking controller.

  Adapters (`CNC.Transport.Sim`, `CNC.Transport.TCP`, later `CNC.Transport.UART`)
  send their owner:

    * `{:transport, :connected}`
    * `{:transport, :line, binary}`
    * `{:transport, :disconnected}`
  """
  use Boundary, deps: [CNC.Grbl], exports: [Sim, TCP]

  @callback start_link(owner :: pid, opts :: keyword) :: GenServer.on_start()
  @callback write_line(pid, iodata) :: :ok
  @callback write_realtime(pid, byte) :: :ok
end
