# Tests tagged :fluidnc_sim run real FluidNC firmware natively; they need
# it built first (mix cnc.fluidnc.build) and are skipped until then.
unless CNC.Link.FluidNCSim.available?() do
  ExUnit.configure(exclude: [:fluidnc_sim])
end

ExUnit.start()
