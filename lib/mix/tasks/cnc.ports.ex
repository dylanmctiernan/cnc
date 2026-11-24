defmodule Mix.Tasks.Cnc.Ports do
  @shortdoc "Lists serial ports, to find the controller board"
  @moduledoc """
  Lists the serial ports on this computer with what the OS knows about them
  (USB vendor, product, serial number).

      mix cnc.ports

  Use the device for `CNC_LINK=uart CNC_UART=<device> mix phx.server`.
  On macOS prefer the `/dev/cu.*` device over `/dev/tty.*`.
  """
  use Mix.Task
  use Boundary, classify_to: CNCApp

  @impl Mix.Task
  def run(_args) do
    case Circuits.UART.enumerate() do
      ports when map_size(ports) == 0 ->
        Mix.shell().info("No serial ports found. Is the board plugged in?")

      ports ->
        for {device, info} <- Enum.sort(ports) do
          details =
            [
              info[:manufacturer],
              info[:description],
              info[:serial_number] && "serial #{info[:serial_number]}"
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(", ")

          path = if String.starts_with?(device, "/dev/"), do: device, else: "/dev/" <> device
          Mix.shell().info(String.trim_trailing("#{path}  #{details}"))
        end
    end
  end
end
