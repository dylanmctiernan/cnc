# Tests tagged :fluidnc_sim run real FluidNC firmware natively; they need
# it built first (fluidnc/build.sh) and are skipped until then.
unless CNC.Transport.FluidNCSim.available?() do
  ExUnit.configure(exclude: [:fluidnc_sim])
end

ExUnit.start()
