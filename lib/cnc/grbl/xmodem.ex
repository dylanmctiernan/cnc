defmodule CNC.Grbl.XModem do
  @moduledoc """
  The sending side of XModem-1K with CRC, as FluidNC receives files
  (`$Xmodem/Receive=<file>`): the receiver asks with `C`, each 1024-byte
  block goes out as `STX n ~n data crc16` and is answered `ACK` (next) or
  `NAK` (again); `EOT` ends it. The last block is padded with Ctrl-Z, which
  FluidNC strips.

  Pure: `CNC.Machine` drives the exchange over the link.
  """
  import Bitwise

  @stx 0x02
  @block 1024

  def ack, do: 0x06
  def nak, do: 0x15
  def can, do: 0x18
  def eot, do: 0x04
  def crc_request, do: ?C

  @doc "The blocks to send, in order (an empty file is one block of padding)."
  @spec packets(binary) :: [binary]
  def packets(data) when is_binary(data) do
    data
    |> chunks()
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, n} -> packet(chunk, n) end)
  end

  defp chunks(<<>>), do: [pad(<<>>)]
  defp chunks(<<chunk::binary-size(@block), rest::binary>>) when rest == <<>>, do: [chunk]
  defp chunks(<<chunk::binary-size(@block), rest::binary>>), do: [chunk | chunks(rest)]
  defp chunks(last), do: [pad(last)]

  defp pad(chunk), do: chunk <> :binary.copy(<<0x1A>>, @block - byte_size(chunk))

  defp packet(chunk, n) do
    n = band(n, 0xFF)
    <<@stx, n, 255 - n, chunk::binary, crc16(chunk)::16>>
  end

  @doc """
  CRC-16/XMODEM (polynomial 0x1021, initial 0).

      iex> CNC.Grbl.XModem.crc16("123456789")
      0x31C3
  """
  @spec crc16(binary) :: 0..0xFFFF
  def crc16(data), do: crc16(data, 0)

  defp crc16(<<>>, crc), do: crc

  defp crc16(<<byte, rest::binary>>, crc) do
    crc =
      Enum.reduce(1..8, bxor(crc, byte <<< 8), fn _, c ->
        if band(c, 0x8000) != 0,
          do: band(bxor(c <<< 1, 0x1021), 0xFFFF),
          else: band(c <<< 1, 0xFFFF)
      end)

    crc16(rest, crc)
  end
end
