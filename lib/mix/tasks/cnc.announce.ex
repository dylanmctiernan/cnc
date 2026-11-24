defmodule Mix.Tasks.Cnc.Announce do
  @shortdoc "Announces this computer as cnc.local on the network (macOS, Bonjour)"
  @moduledoc """
  Announces this computer as `cnc.local` over Bonjour (mDNS), so every
  device on the network (this Mac, phones, iPads) can open
  `http://cnc.local:4000` instead of an IP address or `localhost`.

      mix cnc.announce                  # cnc.local -> this Mac, port 4000
      mix cnc.announce --name shop      # shop.local
      mix cnc.announce --port 4001

  Runs until Ctrl-C, which withdraws the name, so nothing stale is left
  behind. Run it in its own terminal next to
  `CNC_LAN=1 CNC_PIN=… mix phx.server` (the server must listen on the
  network for other devices to reach it).

  A browser treats `cnc.local` as its own site, separate from
  `localhost:4000`, so other apps you run on localhost don't share its
  favicon, cookies or PIN session.

  Stop it once the Raspberry Pi is set up: the Pi announces `cnc.local`
  itself (Nerves, mdns_lite), and two announcers would conflict. Uses macOS's
  `dns-sd`; if this Mac's network address changes, restart it.
  """
  use Mix.Task
  use Boundary, classify_to: CNCApp

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [name: :string, port: :integer])
    name = opts[:name] || "cnc"
    port = opts[:port] || 4000

    dns_sd = System.find_executable("dns-sd") || Mix.raise("dns-sd not found (macOS only)")
    ip = lan_ip() || Mix.raise("no network address found (is Wi-Fi or Ethernet connected?)")

    Mix.shell().info("""
    Announcing #{name}.local -> #{ip} (port #{port}). Ctrl-C to stop.
    Open http://#{name}.local:#{port} on any device on this network.
    """)

    # Foreground: Ctrl-C ends dns-sd with the task and withdraws the name.
    {_, status} =
      System.cmd(
        dns_sd,
        ["-P", "CNC", "_http._tcp", "local", "#{port}", "#{name}.local", ip],
        into: IO.stream(),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("dns-sd exited (#{status})")
  end

  # The address of the first connected interface (Wi-Fi is usually en0).
  defp lan_ip do
    Enum.find_value(~w(en0 en1 en2 en3), fn iface ->
      case System.cmd("ipconfig", ["getifaddr", iface], stderr_to_stdout: true) do
        {ip, 0} -> String.trim(ip)
        _ -> nil
      end
    end)
  end
end
