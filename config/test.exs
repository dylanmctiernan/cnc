import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cnc, CNCWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "l64OGSNzSlUtNIbx3esDeo7vhhW2cPHY9g7xRe8mMvq/3CoQIaIyrXNhWFYDDCoE",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Phoenix.ConnTest's default host (CNCWeb.AllowedHost)
config :cnc, :allowed_hosts, ["www.example.com"]

# Screen tests run their own machine and program store (CNCWeb.Instance).
config :cnc, instance_from_session: true

# Tests use the fake sim directly (a link override, so CNC.Controllers
# leaves the app's machine alone) and never touch the dev data folder.
config :cnc, :link, adapter: CNC.Link.FakeSim, opts: []
config :cnc, :data_dir, Path.join(System.tmp_dir!(), "cnc-test-data")
