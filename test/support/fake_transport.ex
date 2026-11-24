defmodule CNC.FakeTransport do
  @moduledoc """
  Transport adapter for tests. Every write is forwarded to the test process
  as `{:line, binary}` or `{:rt, byte}`; the test plays controller by sending
  `{:transport, :line, "..."}` to the owner directly.

  On start it sends the test `{:fake_transport, pid, owner}`.
  """
  @behaviour CNC.Transport
  use GenServer

  @impl CNC.Transport
  def start_link(owner, opts), do: GenServer.start_link(__MODULE__, {owner, opts[:test]})

  @impl CNC.Transport
  def write_line(pid, line), do: GenServer.cast(pid, {:line, IO.iodata_to_binary(line)})

  @impl CNC.Transport
  def write_realtime(pid, byte), do: GenServer.cast(pid, {:rt, byte})

  @impl GenServer
  def init({owner, test}) do
    send(test, {:fake_transport, self(), owner})
    send(owner, {:transport, :connected})
    {:ok, test}
  end

  @impl GenServer
  def handle_cast(write, test) do
    send(test, write)
    {:noreply, test}
  end
end
