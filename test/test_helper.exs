# Tests tagged :grblhal_sim need a running grblHAL simulator:
#   GRBLHAL_SIM=localhost:2323 mix test --only grblhal_sim
ExUnit.configure(exclude: [:grblhal_sim])
ExUnit.start()
