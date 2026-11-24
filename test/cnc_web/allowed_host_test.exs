defmodule CNCWeb.AllowedHostTest do
  use CNCWeb.ConnCase, async: true

  alias CNCWeb.AllowedHost

  doctest AllowedHost

  @allowed ~w(
    localhost LOCALHOST localhost. 127.0.0.1 [::1] ::1
    cnc-1a2b.local shop.local. pi.lan.local
    192.168.1.20 10.0.0.5 172.16.0.1 172.31.255.254 169.254.10.10
    [fd12:3456:789a::1] [fe80::1] [::ffff:192.168.1.20]
  )

  @refused ~w(
    evil.example.com localhost.evil.example.com local .local example.local.com
    8.8.8.8 172.32.0.1 192.169.0.1 0.0.0.0 [2001:4860:4860::8888] [::ffff:8.8.8.8]
  ) ++ [""]

  test "local names and private addresses are served" do
    for host <- @allowed, do: assert(AllowedHost.allowed?(host), host)
  end

  test "public names and addresses are refused" do
    for host <- @refused, do: refute(AllowedHost.allowed?(host), host)
  end

  test "extra names from config are served" do
    # config/test.exs adds Phoenix.ConnTest's default host
    assert AllowedHost.allowed?("www.example.com")
  end

  test "the plug passes allowed hosts and halts the rest with a 400", %{conn: conn} do
    passed = AllowedHost.call(%{conn | host: "192.168.1.20"}, [])
    refute passed.halted

    refused = AllowedHost.call(%{conn | host: "evil.example.com"}, [])
    assert refused.halted
    assert refused.status == 400
  end

  test "the endpoint refuses other hosts, pages and sockets alike", %{conn: conn} do
    for path <- ["/", "/pendant", "/live/websocket", "/live/longpoll"] do
      conn = get(%{recycle(conn) | host: "evil.example.com"}, path)
      assert response(conn, 400) =~ "isn't served", path
    end
  end
end
