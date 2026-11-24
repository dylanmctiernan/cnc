defmodule CNC.Link.TCPTest do
  use ExUnit.Case, async: true

  alias CNC.Link.TCP

  # A local listener plays the controller.
  setup do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)
    %{listen: listen, port: port}
  end

  defp connect(%{listen: listen, port: port}) do
    Process.flag(:trap_exit, true)
    {:ok, pid} = TCP.start_link(self(), host: "localhost", port: port)
    {:ok, server} = :gen_tcp.accept(listen, 1000)
    assert_receive {:link, :connected}
    {pid, server}
  end

  test "writes lines with a newline and real-time bytes raw", ctx do
    {pid, server} = connect(ctx)
    TCP.write_line(pid, ["$J=G91 ", "X1"])
    TCP.write_realtime(pid, 0x85)
    assert {:ok, "$J=G91 X1\n" <> <<0x85>>} = recv_all(server, 11)
  end

  test "frames incoming lines and strips line endings", ctx do
    {_pid, server} = connect(ctx)
    :ok = :gen_tcp.send(server, "ok\r\n<Idle|MPos:0.000,")
    :ok = :gen_tcp.send(server, "0.000,0.000|FS:0,0>\r\nerror:15\n")

    assert_receive {:link, :line, "ok"}
    assert_receive {:link, :line, "<Idle|MPos:0.000,0.000,0.000|FS:0,0>"}
    assert_receive {:link, :line, "error:15"}
  end

  test "close delivers queued writes first, then closes", ctx do
    {pid, server} = connect(ctx)
    TCP.write_realtime(pid, 0x85)
    TCP.close(pid)
    assert {:ok, <<0x85>>} = :gen_tcp.recv(server, 0, 1000)
    assert {:error, :closed} = :gen_tcp.recv(server, 0, 1000)
    assert_receive {:EXIT, ^pid, {:shutdown, :closed}}
  end

  test "controller closing the socket disconnects and exits", ctx do
    {pid, server} = connect(ctx)
    :gen_tcp.close(server)
    assert_receive {:link, :disconnected}
    assert_receive {:EXIT, ^pid, {:shutdown, :closed}}
  end

  test "connect failure exits without claiming a connection" do
    Process.flag(:trap_exit, true)
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    {:ok, pid} = TCP.start_link(self(), host: "localhost", port: port)
    assert_receive {:EXIT, ^pid, {:shutdown, {:connect_failed, :econnrefused}}}
    refute_received {:link, :connected}
  end

  defp recv_all(socket, n, acc \\ "") do
    if byte_size(acc) >= n do
      {:ok, acc}
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0, 1000), do: recv_all(socket, n, acc <> data)
    end
  end
end
