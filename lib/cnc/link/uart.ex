defmodule CNC.Link.UART do
  @moduledoc """
  Serial link to a Grbl-speaking controller (FluidNC over USB), via
  `Circuits.UART`.

  Opens the port after `start_link/2` returns, then sends the owner
  `{:link, :connected}`. Lines arrive as `{:link, :line, line}`
  without their line ending (FluidNC sends `\\r\\n`). On a read error (e.g.
  the cable is pulled) it sends `{:link, :disconnected}` and exits; the
  owner reconnects with backoff.

  Framing is done here rather than by `Circuits.UART.Framing.Line`, because
  that framer appends a newline to every write, and real-time bytes (`?`,
  `0x85`, ...) must go out bare.

  Options: `:port` (required, e.g. `"/dev/cu.usbserial-0001"`, see
  `CNC.Link.UART.ports/0`), `:speed` (default 115200).

  Note: opening the port may reset an ESP32 board (DTR/RTS); the controller
  then boots, which the Machine treats like any reset (it re-locks).
  """
  @behaviour CNC.Link
  use GenServer
  require Logger

  @impl CNC.Link
  def start_link(owner, opts), do: GenServer.start_link(__MODULE__, {owner, opts})

  @impl CNC.Link
  def write_line(pid, line), do: GenServer.cast(pid, {:write, [line, ?\n]})

  @impl CNC.Link
  def write_realtime(pid, byte), do: GenServer.cast(pid, {:write, <<byte>>})

  @impl CNC.Link
  def close(pid), do: GenServer.cast(pid, :close)

  @doc "Serial ports present on this computer, with whatever the OS knows about them."
  def ports, do: Circuits.UART.enumerate()

  @impl GenServer
  def init({owner, opts}) do
    {:ok, uart} = Circuits.UART.start_link()
    {:ok, %{owner: owner, opts: opts, uart: uart, buffer: ""}, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, %{opts: opts} = s) do
    port = Keyword.fetch!(opts, :port)
    speed = Keyword.get(opts, :speed, 115_200)

    case Circuits.UART.open(s.uart, port, speed: speed, active: true) do
      :ok ->
        send(s.owner, {:link, :connected})
        {:noreply, s}

      {:error, reason} ->
        Logger.warning("serial open #{port} failed: #{inspect(reason)}")
        {:stop, {:shutdown, {:connect_failed, reason}}, s}
    end
  end

  @impl GenServer
  def handle_cast(:close, s) do
    # Wait until queued bytes are actually sent: closing a serial port can
    # discard output still in the OS buffer, and the watchdog's last write
    # before closing is a jog cancel.
    _ = Circuits.UART.drain(s.uart)
    Circuits.UART.close(s.uart)
    {:stop, {:shutdown, :closed}, s}
  end

  def handle_cast({:write, data}, s) do
    case Circuits.UART.write(s.uart, data) do
      :ok -> {:noreply, s}
      {:error, reason} -> disconnect(s, reason)
    end
  end

  @impl GenServer
  def handle_info({:circuits_uart, _port, {:error, reason}}, s), do: disconnect(s, reason)

  def handle_info({:circuits_uart, _port, data}, s) when is_binary(data) do
    {lines, rest} = split_lines(s.buffer <> data)
    for line <- lines, do: send(s.owner, {:link, :line, line})
    {:noreply, %{s | buffer: rest}}
  end

  defp disconnect(s, reason) do
    send(s.owner, {:link, :disconnected})
    {:stop, {:shutdown, reason}, s}
  end

  # Complete lines (without \r\n) and the unterminated remainder.
  defp split_lines(data) do
    parts = String.split(data, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.map(complete, &String.trim_trailing(&1, "\r")), rest}
  end
end
