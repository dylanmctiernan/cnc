# Tests tagged :native_fluidnc run real FluidNC firmware natively; they need
# it built first (fluidnc/build.sh) and are skipped until then.
unless CNC.Transport.NativeFluidNC.available?() do
  ExUnit.configure(exclude: [:native_fluidnc])
end

ExUnit.start()
