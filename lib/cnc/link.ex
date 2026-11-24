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
    * `{:link, :data, binary}` — bytes as they come, while in raw mode

  Sending a file to the controller: a link that holds the controller's
  files itself (the sims) implements `upload/3`; one to real hardware
  implements `raw_mode/2` and `write_raw/2`, and `CNC.Machine` runs XModem
  over it.
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
  @doc "Raw mode on: incoming bytes go to the owner as `{:link, :data, bytes}`, not lines."
  @callback raw_mode(pid, boolean) :: :ok
  @doc "Write bytes exactly (in raw mode, for a file transfer)."
  @callback write_raw(pid, iodata) :: :ok
  @doc "Put a file onto the controller directly: `{:ok, bytes}` or an error."
  @callback upload(pid, name :: String.t(), data :: binary) ::
              {:ok, non_neg_integer} | {:error, term}

  @optional_callbacks simulated?: 0, raw_mode: 2, write_raw: 2, upload: 3

  @doc "Whether `adapter` declares itself simulated."
  def simulated?(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :simulated?, 0) and
      adapter.simulated?()
  end
end
