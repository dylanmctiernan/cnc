defmodule Mix.Tasks.Cnc.Fluidnc.Flash do
  @shortdoc "Flashes an ESP32 with FluidNC and a config over USB"
  @moduledoc """
  Builds FluidNC for a classic ESP32 (same pinned commit as the sim) and
  writes it to the board over USB, then writes the board's small file system
  holding the config as `config.yaml`.

      mix cnc.fluidnc.flash /dev/cu.usbserial-0001
      mix cnc.fluidnc.flash /dev/cu.usbserial-0001 --config priv/fluidnc/other.yaml
      mix cnc.fluidnc.flash --build-only            # no board needed

  The default config is `priv/fluidnc/esp32_bench.yaml`. It's FluidNC's
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
    {opts, rest} = OptionParser.parse!(args, strict: [config: :string, build_only: :boolean])
    config = Path.expand(opts[:config] || "priv/fluidnc/esp32_bench.yaml")
    File.exists?(config) || Mix.raise("no such config: #{config}")

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
    File.cp!(config, Path.join([FluidNC.src_dir(), "FluidNC", "data", "config.yaml"]))

    if port do
      FluidNC.pio!(["run", "-e", @env, "-t", "upload", "--upload-port", port])
      FluidNC.pio!(["run", "-e", @env, "-t", "uploadfs", "--upload-port", port])

      Mix.shell().info(
        "Flashed FluidNC #{FluidNC.short_commit()} (#{@env}) with #{Path.basename(config)} to #{port}"
      )
    else
      FluidNC.pio!(["run", "-e", @env])
      FluidNC.pio!(["run", "-e", @env, "-t", "buildfs"])
      Mix.shell().info("Built firmware and file system (#{@env}); not flashed")
    end
  end
end
