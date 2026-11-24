defmodule CNC.Link.UARTTest do
  @moduledoc """
  The UART adapter against a virtual serial port (a pseudo-terminal made by
  test/support/pty_bridge.py). The test plays the controller on the other
  end: what it sends arrives at the adapter as if from the board.
  """
  use ExUnit.Case, async: true

  alias CNC.Link.UART

  @bridge Path.expand("../../support/pty_bridge.py", __DIR__)

  setup do
    python = System.find_executable("python3") || flunk("python3 is needed for the pty bridge")

    port =
      Port.open({:spawn_executable, python}, [:binary, :exit_status, args: ["-I", @bridge]])

    assert_receive {^port, {:data, first}}, 2000
    [device | _] = String.split(first, "\n")
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    %{device: device, board: port}
  end

  defp open(%{device: device}) do
    Process.flag(:trap_exit, true)
    {:ok, pid} = UART.start_link(self(), port: device)
    assert_receive {:link, :connected}, 2000
    pid
  end

  # What the adapter wrote to the "board", collected until it has n bytes.
  defp board_received(board, n, acc \\ "") do
    if byte_size(acc) >= n do
      acc
    else
      assert_receive {^board, {:data, data}}, 1000
      board_received(board, n, acc <> data)
    end
  end

  test "writes lines with a newline and real-time bytes bare", %{board: board} = ctx do
    pid = open(ctx)
    UART.write_line(pid, "$J=G91 G21 X1.000 F1200")
    UART.write_realtime(pid, 0x85)
    UART.write_realtime(pid, ??)

    assert board_received(board, 26) == "$J=G91 G21 X1.000 F1200\n" <> <<0x85, ??>>
  end

  test "frames \\r\\n lines split across reads", %{board: board} = ctx do
    open(ctx)
    Port.command(board, "ok\r\n<Idle|MPos:1.000,")
    Process.sleep(20)
    Port.command(board, "2.000,0.000|FS:0,0>\r\nerror:15\r\n[MSG:partial")

    assert_receive {:link, :line, "ok"}
    assert_receive {:link, :line, "<Idle|MPos:1.000,2.000,0.000|FS:0,0>"}
    assert_receive {:link, :line, "error:15"}
    refute_receive {:link, :line, "[MSG:partial"}, 100
  end

  test "close delivers queued writes first, then closes", %{board: board} = ctx do
    pid = open(ctx)
    UART.write_realtime(pid, 0x85)
    UART.close(pid)
    assert board_received(board, 1) == <<0x85>>
    assert_receive {:EXIT, ^pid, {:shutdown, :closed}}
  end

  test "pulling the cable disconnects and exits", %{board: board} = ctx do
    pid = open(ctx)
    Port.close(board)
    assert_receive {:link, :disconnected}, 2000
    assert_receive {:EXIT, ^pid, {:shutdown, _reason}}
  end

  test "a missing port fails to connect" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = UART.start_link(self(), port: "/dev/cu.does-not-exist")
    assert_receive {:EXIT, ^pid, {:shutdown, {:connect_failed, _}}}, 2000
    refute_received {:link, :connected}
  end

  test "Machine talks to a 'board' over the serial link", %{board: board, device: device} do
    topic = "uart-#{System.unique_integer([:positive])}"
    spec = {CNC.Machine, name: nil, link: {UART, port: device}, topic: topic}
    m = start_supervised!(Supervisor.child_spec(spec, id: make_ref()))

    # Machine polls; the board answers with a status report.
    assert board_received(board, 1) =~ "?"
    Port.command(board, "<Idle|MPos:10.000,20.000,0.000|FS:0,0>\r\n")

    # Then it asks for settings.
    assert eventually(fn -> board_has(board, "$$\n") end)
    Port.command(board, "$130=800.000\r\n$131=600.000\r\n$132=90.000\r\nok\r\n")

    assert eventually(fn -> CNC.Machine.status(m).travel_source == :controller end)

    assert %CNC.Machine.State{
             state: :alarm,
             mpos: {10.0, 20.0, +0.0},
             travel: {{+0.0, 800.0}, {+0.0, 600.0}, {-90.0, +0.0}}
           } = CNC.Machine.status(m)
  end

  defp board_has(board, text) do
    receive do
      {^board, {:data, data}} -> String.contains?(data, text) or board_has(board, text)
    after
      50 -> false
    end
  end

  defp eventually(fun, timeout \\ 2000) do
    cond do
      fun.() -> true
      timeout <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, timeout - 20)
    end
  end
end
