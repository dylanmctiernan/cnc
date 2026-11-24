# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cnc,
  namespace: CNC,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :cnc, CNCWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CNCWeb.ErrorHTML, json: CNCWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CNC.PubSub,
  live_view: [signing_salt: "resrjewd"]

# Controller link. Dev/test default is the in-process simulator.
config :cnc, :transport, adapter: CNC.Transport.Sim, opts: []

# The machine's physical travel in mm (machine coordinates, origin front-left
# after homing). After connecting, the Machine reads the controller's
# $130-$132: they may narrow this but never widen it (wider values are capped
# and flagged). Used as-is until then, or if they're missing.
config :cnc, :machine, travel: {{0.0, 1250.0}, {0.0, 1250.0}, {-100.0, 0.0}}

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  cnc: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  cnc: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
