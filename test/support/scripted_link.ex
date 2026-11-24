defmodule CNC.ScriptedLink do
  @moduledoc """
  Link adapter for tests. Every write is forwarded to the test process
  as `{:line, binary}` or `{:rt, byte}`; the test plays controller by sending
  `{:link, :line, "..."}` to the owner directly.

  On start it sends the test `{:scripted_link, pid, owner}`.
  """
  @behaviour CNC.Link
  use GenServer

  @impl CNC.Link
  def start_link(owner, opts), do: GenServer.start_link(__MODULE__, {owner, opts[:test]})

  @impl CNC.Link
  def write_line(pid, line), do: GenServer.cast(pid, {:line, IO.iodata_to_binary(line)})

  @impl CNC.Link
  def write_realtime(pid, byte), do: GenServer.cast(pid, {:rt, byte})

  @impl CNC.Link
  def close(pid), do: GenServer.cast(pid, :close)

  @impl GenServer
  def init({owner, test}) do
    send(test, {:scripted_link, self(), owner})
    send(owner, {:link, :connected})
    {:ok, test}
  end

  @impl GenServer
  def handle_cast(:close, test), do: {:stop, {:shutdown, :closed}, test}

  def handle_cast(write, test) do
    send(test, write)
    {:noreply, test}
  end
end
