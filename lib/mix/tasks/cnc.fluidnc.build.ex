defmodule Mix.Tasks.Cnc.Fluidnc.Build do
  @shortdoc "Builds the FluidNC sim (real FluidNC as a program on this computer)"
  @moduledoc """
  Builds the FluidNC sim: stock FluidNC compiled to run natively on this
  computer (macOS or Linux), with step pulses counted instead of sent to
  pins. Dev uses it automatically once built (`CNC.Transport.FluidNCSim`,
  config `priv/fluidnc/sim.yaml`), and the `:fluidnc_sim` tests run against it.

      mix cnc.fluidnc.build        # -> .fluidnc/bin/fluidnc

  Needs git and python3. The first build installs PlatformIO into
  `.fluidnc/venv` and fetches libraries (~2 min); rebuilds take ~30 s.
  Restart the dev server afterwards.
  """
  use Mix.Task
  use Boundary, classify_to: CNCApp

  alias CNCApp.FluidNCSource, as: FluidNC

  @impl Mix.Task
  def run(_args) do
    env =
      case :os.type() do
        {:unix, :darwin} -> "macos"
        {:unix, :linux} -> "linux"
        other -> Mix.raise("no FluidNC native build for #{inspect(other)}")
      end

    FluidNC.checkout!()
    FluidNC.pio!(["run", "-e", env])

    # Replace, don't overwrite: macOS ties a program's code signature to the
    # file it first ran from and kills a binary rewritten in place (exit 137).
    bin = FluidNC.bin_path()
    File.rm(bin)
    File.cp!(Path.join([FluidNC.src_dir(), ".pio", "build", env, "program"]), bin)
    Mix.shell().info("Built #{bin} (FluidNC #{FluidNC.short_commit()}, #{env})")
  end
end
