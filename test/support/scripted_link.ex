defmodule CNC.ScriptedLink do
  @moduledoc """
  Link adapter for tests. Every write is forwarded to the test process
  as `{:line, binary}`, `{:rt, byte}` or (raw mode) `{:raw, bytes}`; the test plays controller by sending
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

  # File transfers: the test sees {:raw_mode, on?} and {:raw, bytes}.
  @impl CNC.Link
  def raw_mode(pid, on?), do: GenServer.cast(pid, {:raw_mode, on?})

  @impl CNC.Link
  def write_raw(pid, data), do: GenServer.cast(pid, {:raw, IO.iodata_to_binary(data)})

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
