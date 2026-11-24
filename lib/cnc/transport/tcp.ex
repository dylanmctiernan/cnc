defmodule CNC.Transport.TCP do
  @moduledoc """
  Raw TCP link to a Grbl-speaking controller: the grblHAL simulator
  (`grblHAL_sim -p 2323`), or later FluidNC's telnet port.

  Connects after `start_link/2` returns (so a dead host doesn't block the
  owner), then sends the owner `{:transport, :connected}`. Lines arrive as
  `{:transport, :line, line}` without their line ending. On close or error it
  sends `{:transport, :disconnected}` and exits; the owner reconnects.

  Options: `:host` (default `"localhost"`), `:port` (default 2323),
  `:connect_timeout` ms (default 2000).
  """
  @behaviour CNC.Transport
  use GenServer
  require Logger

  @impl CNC.Transport
  def start_link(owner, opts), do: GenServer.start_link(__MODULE__, {owner, opts})

  @impl CNC.Transport
  def write_line(pid, line), do: GenServer.cast(pid, {:send, [line, ?\n]})

  @impl CNC.Transport
  def write_realtime(pid, byte), do: GenServer.cast(pid, {:send, <<byte>>})

  @impl CNC.Transport
  def close(pid), do: GenServer.cast(pid, :close)

  @impl GenServer
  def init({owner, opts}),
    do: {:ok, %{owner: owner, opts: opts, socket: nil}, {:continue, :connect}}

  @impl GenServer
  def handle_continue(:connect, %{opts: opts} = s) do
    host = opts |> Keyword.get(:host, "localhost") |> to_charlist()
    port = Keyword.get(opts, :port, 2323)
    timeout = Keyword.get(opts, :connect_timeout, 2000)

    # packet: :line frames for us; nodelay because '?' polls are single bytes.
    tcp_opts = [:binary, packet: :line, active: :once, nodelay: true]

    case :gen_tcp.connect(host, port, tcp_opts, timeout) do
      {:ok, socket} ->
        send(s.owner, {:transport, :connected})
        {:noreply, %{s | socket: socket}}

      {:error, reason} ->
        Logger.warning("TCP connect to #{host}:#{port} failed: #{inspect(reason)}")
        {:stop, {:shutdown, {:connect_failed, reason}}, s}
    end
  end

  @impl GenServer
  def handle_cast(:close, s) do
    if s.socket, do: :gen_tcp.close(s.socket)
    {:stop, {:shutdown, :closed}, s}
  end

  def handle_cast({:send, data}, s) do
    case :gen_tcp.send(s.socket, data) do
      :ok -> {:noreply, s}
      {:error, reason} -> disconnect(s, reason)
    end
  end

  @impl GenServer
  def handle_info({:tcp, socket, data}, %{socket: socket} = s) do
    line = data |> String.trim_trailing("\n") |> String.trim_trailing("\r")
    send(s.owner, {:transport, :line, line})
    :ok = :inet.setopts(socket, active: :once)
    {:noreply, s}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = s), do: disconnect(s, :closed)
  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = s), do: disconnect(s, reason)

  defp disconnect(s, reason) do
    send(s.owner, {:transport, :disconnected})
    {:stop, {:shutdown, reason}, s}
  end
end
