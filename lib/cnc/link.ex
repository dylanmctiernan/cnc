defmodule CNC.Link do
  @moduledoc """
  Link port: a line-level connection to a Grbl-speaking controller.

  Adapters: `CNC.Link.FakeSim` (in-process fake), `CNC.Link.FluidNCSim`
  (FluidNC as a local program), `CNC.Link.UART` and `CNC.Link.TCP`
  (a real controller)
  send their owner:

    * `{:link, :connected}`
    * `{:link, :line, binary}`
    * `{:link, :disconnected}`
  """
  use Boundary, deps: [CNC.Grbl], exports: [FakeSim, FluidNCSim, TCP, UART]

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
