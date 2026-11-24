defmodule CNC.Transport do
  @moduledoc """
  Transport port: line-level link to a Grbl-speaking controller.

  Adapters: `CNC.Transport.Sim` (in-process fake), `CNC.Transport.NativeFluidNC`
  (FluidNC as a local program), `CNC.Transport.UART` and `CNC.Transport.TCP`
  (a real controller)
  send their owner:

    * `{:transport, :connected}`
    * `{:transport, :line, binary}`
    * `{:transport, :disconnected}`
  """
  use Boundary, deps: [CNC.Grbl], exports: [NativeFluidNC, Sim, TCP, UART]

  @callback start_link(owner :: pid, opts :: keyword) :: GenServer.on_start()
  @callback write_line(pid, iodata) :: :ok
  @callback write_realtime(pid, byte) :: :ok
  @doc "Finish writes already queued, then disconnect (and exit)."
  @callback close(pid) :: :ok

  @doc """
  True if nothing physical is on the other end (the UI labels it a
  simulator). Optional; links to real hardware leave it out.
  """
  @callback simulated?() :: boolean
  @optional_callbacks simulated?: 0

  @doc "Whether `adapter` declares itself simulated."
  def simulated?(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :simulated?, 0) and
      adapter.simulated?()
  end
end
