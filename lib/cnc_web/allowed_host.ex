defmodule CNCWeb.AllowedHost do
  @moduledoc """
  Serves only requests addressed to a name or address on the home network.

  The app has no login: it runs on the LAN for one user. What it must stop
  is a website in that user's browser driving the machine. A page from
  another site can't open the LiveView socket (`check_origin: :conn`), but
  with DNS rebinding a site's own name can be pointed at this machine, so
  its pages count as same-origin. Its requests still carry that public name
  in `Host`, and that is what this plug turns away.

  Allowed: `localhost`, mDNS names (`*.local`), loopback and private-network
  addresses (10/8, 172.16/12, 192.168/16, 169.254/16, IPv6 loopback, fc00::/7,
  fe80::/10, and IPv4 addresses mapped into IPv6), plus any names in
  `config :cnc, :allowed_hosts`. Anything else gets a plain 400.

  The endpoint calls it ahead of everything, sockets included.
  """
  import Plug.Conn
  import Bitwise

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if allowed?(conn.host) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(400, "This address isn't served. Open the app by its local name or address.\n")
      |> halt()
    end
  end

  @doc """
  Whether a request for `host` (as in `conn.host`) is served.

      iex> CNCWeb.AllowedHost.allowed?("cnc-1a2b.local")
      true
      iex> CNCWeb.AllowedHost.allowed?("evil.example.com")
      false
  """
  def allowed?(host) when is_binary(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    host in ["localhost" | extra_hosts()] or mdns?(host) or private_ip?(host)
  end

  def allowed?(_), do: false

  defp extra_hosts, do: Application.get_env(:cnc, :allowed_hosts, [])

  # A name under .local, e.g. "shop.local" (not ".local" alone)
  defp mdns?(host) do
    labels = String.split(host, ".")
    length(labels) >= 2 and List.last(labels) == "local" and "" not in labels
  end

  defp private_ip?(host) do
    literal = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_strict_address(String.to_charlist(literal)) do
      {:ok, ip} -> private?(ip)
      {:error, _} -> false
    end
  end

  defp private?({127, _, _, _}), do: true
  defp private?({10, _, _, _}), do: true
  defp private?({172, b, _, _}) when b in 16..31, do: true
  defp private?({192, 168, _, _}), do: true
  defp private?({169, 254, _, _}), do: true
  defp private?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv4-mapped (::ffff:a.b.c.d)
  defp private?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: private?({ab >>> 8, ab &&& 0xFF, cd >>> 8, cd &&& 0xFF})

  # Unique local (fc00::/7) and link-local (fe80::/10)
  defp private?({a, _, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: true
  defp private?({a, _, _, _, _, _, _, _}) when (a &&& 0xFFC0) == 0xFE80, do: true
  defp private?(_), do: false
end
