import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/cnc start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :cnc, CNCWeb.Endpoint, server: true
end

config :cnc, CNCWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# CNC_LAN=1 serves the UI to other devices on the local network (dev only).
# There's no login: anyone on the network can drive the machine. Only local
# names and addresses are served (CNCWeb.AllowedHost) and only the app's own
# pages may connect (check_origin), so a website can't reach it through a
# browser; keep the network itself private (no port forwarding).
if config_env() == :dev and System.get_env("CNC_LAN") in ~w(1 true) do
  config :cnc, CNCWeb.Endpoint, http: [ip: {0, 0, 0, 0}]
end

# Controller link override. Normally the active controller profile is used
# (CNC.Controllers: pick one in Settings); setting CNC_LINK bypasses the
# profiles for scripts and one-offs. Tests always use the fake sim (test.exs).
#   CNC_LINK=fake mix phx.server            # fake sim (built in)
#   CNC_LINK=tcp CNC_TCP=fluidnc.local:23 mix phx.server   # FluidNC over Wi-Fi (telnet)
#   CNC_LINK=uart CNC_UART=/dev/cu.usbserial-0001 mix phx.server
#   CNC_UART_SPEED=115200                   # default; see `mix cnc.ports`
case System.get_env("CNC_LINK") do
  nil ->
    :ok

  "fake" ->
    config :cnc, :link, adapter: CNC.Link.FakeSim, opts: []

  "tcp" ->
    target = System.get_env("CNC_TCP") || raise "CNC_LINK=tcp needs CNC_TCP=<host>[:port]"
    [host | port] = String.split(target, ":")
    port = List.first(port, "23")

    config :cnc, :link,
      adapter: CNC.Link.TCP,
      opts: [host: host, port: String.to_integer(port)]

  "uart" ->
    port =
      System.get_env("CNC_UART") ||
        raise "CNC_LINK=uart needs CNC_UART=<device> (see mix cnc.ports)"

    config :cnc, :link,
      adapter: CNC.Link.UART,
      opts: [port: port, speed: String.to_integer(System.get_env("CNC_UART_SPEED", "115200"))]

  other ->
    raise "unknown CNC_LINK #{inspect(other)} (expected fake, tcp or uart)"
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :cnc, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :cnc, CNCWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :cnc, CNCWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :cnc, CNCWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
