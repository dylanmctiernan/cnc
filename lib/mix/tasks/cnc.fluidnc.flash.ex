defmodule Mix.Tasks.Cnc.Fluidnc.Flash do
  @shortdoc "Flashes an ESP32 with FluidNC and a config over USB"
  @moduledoc """
  Builds FluidNC for a classic ESP32 (same pinned commit as the sim) and
  writes it to the board over USB, then writes the board's small file system
  holding the config as `config.yaml`.

      mix cnc.fluidnc.flash /dev/cu.usbserial-0001                 # ESP32 DevKit
      mix cnc.fluidnc.flash /dev/cu.usbserial-0001 --board six_x   # the 6x board
      mix cnc.fluidnc.flash /dev/cu.usbserial-0001 --config my.yaml
      mix cnc.fluidnc.flash --build-only                           # no board needed

  The config is the board's default (`CNC.Boards`: this machine,
  from `priv/fluidnc/config.yaml.eex`, with the board's pins), or a file
  given with `--config`. After this, the board's own config is the source of
  truth: change it from the app's Settings rather than by reflashing. It's FluidNC's
  `noradio` build: serial only, so the board never starts a Wi-Fi access
  point. Find the port with `mix cnc.ports`, and close anything holding it
  (the dev server on `uart`) first. If the upload stops at "Connecting...",
  hold the board's BOOT button until it starts.

  The first run downloads the ESP32 toolchain (a few minutes).
  """
  use Mix.Task
  use Boundary, classify_to: CNCApp

  alias CNCApp.FluidNCSource, as: FluidNC

  @env "noradio"

  @impl Mix.Task
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(args, strict: [config: :string, board: :string, build_only: :boolean])

    config_text =
      case {opts[:config], opts[:board] || "esp32_devkit"} do
        {nil, board} -> board |> board_id() |> CNC.Boards.config()
        {file, _} -> File.read!(Path.expand(file))
      end

    port =
      case {rest, opts[:build_only]} do
        {[], true} ->
          nil

        {[port], _} ->
          port

        _ ->
          Mix.raise("usage: mix cnc.fluidnc.flash <serial port> [--config file] | --build-only")
      end

    FluidNC.checkout!()
    File.write!(Path.join([FluidNC.src_dir(), "FluidNC", "data", "config.yaml"]), config_text)

    if port do
      FluidNC.pio!(["run", "-e", @env, "-t", "upload", "--upload-port", port])
      FluidNC.pio!(["run", "-e", @env, "-t", "uploadfs", "--upload-port", port])

      Mix.shell().info(
        "Flashed FluidNC #{FluidNC.short_commit()} (#{@env}) and its config to #{port}"
      )
    else
      FluidNC.pio!(["run", "-e", @env])
      FluidNC.pio!(["run", "-e", @env, "-t", "buildfs"])
      Mix.shell().info("Built firmware and file system (#{@env}); not flashed")
    end
  end

  defp board_id(name) do
    Enum.find(CNC.Boards.ids(), &(Atom.to_string(&1) == name)) ||
      Mix.raise(
        "unknown board #{name} (#{Enum.map_join(CNC.Boards.ids(), ", ", &Atom.to_string/1)})"
      )
  end
end
