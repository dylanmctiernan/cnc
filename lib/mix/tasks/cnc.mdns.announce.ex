defmodule Mix.Tasks.Cnc.Mdns.Announce do
  @shortdoc "Announces this computer as cnc-XXXX.local, or a name you choose (mDNS, macOS)"
  @moduledoc """
  Announces this computer on the local network over mDNS (Bonjour), so any
  device here (this Mac, phones, iPads) can open the app by one name:

    * by default `cnc-XXXX.local`, where XXXX is a short random id made once
      and kept in `.cnc/device-id`: stable across runs, and two machines
      never share a name;
    * or the name you give with `--name` (e.g. `shop` for `shop.local`).

  Examples:

      mix cnc.mdns.announce                 # cnc-XXXX.local
      mix cnc.mdns.announce --name shop     # shop.local
      mix cnc.mdns.announce --port 4001

  Runs until Ctrl-C, which withdraws the name. If the task is killed
  instead, a small watchdog stops dns-sd within a second, so nothing stale
  is left announced. Run it in its own terminal next to
  `CNC_LAN=1 CNC_PIN=… mix phx.server` (the server must listen on the
  network for other devices to reach it).

  A browser treats these names as their own sites, separate from
  `localhost:4000`, so other apps you run on localhost don't share their
  favicon, cookies or PIN session.

  Stop it once the Raspberry Pi is set up: the Pi announces its own name
  (Nerves, mdns_lite). Uses macOS's `dns-sd`; if this Mac's network address
  changes, restart it.
  """
  use Mix.Task
  use Boundary, classify_to: CNCApp

  # No 0/o, 1/l/i: easy to read aloud and type
  @alphabet ~c"abcdefghjkmnpqrstuvwxyz23456789"
  @id_length 4
  @id_file ".cnc/device-id"

  # Runs dns-sd ("$@") and stops it when this task goes away, however it
  # ends (Ctrl-C reaches both; a kill only reaches the BEAM, so the loop
  # notices its parent is gone).
  @watchdog """
  "$@" &
  child=$!
  trap 'kill "$child" 2>/dev/null' EXIT HUP INT TERM
  parent=$PPID
  while kill -0 "$child" 2>/dev/null; do
    kill -0 "$parent" 2>/dev/null || exit 0
    sleep 1
  done
  trap - EXIT
  wait "$child"
  """

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [name: :string, port: :integer])
    http_port = opts[:port] || 4000
    name = opts[:name] || "cnc-#{device_id()}"

    dns_sd = System.find_executable("dns-sd") || Mix.raise("dns-sd not found (macOS only)")
    ip = lan_ip() || Mix.raise("no network address found (is Wi-Fi or Ethernet connected?)")

    Mix.shell().info("""
    Announcing #{name}.local -> #{ip} (port #{http_port}). Ctrl-C to stop.
    Open http://#{name}.local:#{http_port} on any device on this network.
    """)

    announcer =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args:
          ["-c", @watchdog, "announce", dns_sd] ++
            ["-P", name, "_http._tcp", "local", "#{http_port}", "#{name}.local", ip]
      ])

    relay(announcer)
  end

  defp relay(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        relay(port)

      {^port, {:exit_status, status}} ->
        Mix.raise("dns-sd exited (#{status})")
    end
  end

  @doc false
  # The short id for this computer: read from .cnc/device-id, made once.
  def device_id do
    case File.read(@id_file) do
      {:ok, id} when byte_size(id) > 0 ->
        String.trim(id)

      _ ->
        id = for _ <- 1..@id_length, into: "", do: <<Enum.random(@alphabet)>>
        File.mkdir_p!(Path.dirname(@id_file))
        File.write!(@id_file, id <> "\n")
        id
    end
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
