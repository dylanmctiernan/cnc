defmodule CNC.Machine.ConsoleTest do
  use CNC.MachineCase, async: true

  describe "console" do
    setup do
      topic = "console-#{System.unique_integer([:positive])}"
      m = start_machine({CNC.ScriptedLink, test: self()}, topic)
      assert_receive {:scripted_link, _fake, ^m}
      Machine.subscribe_console(topic)
      %{m: m, topic: topic}
    end

    test "logs traffic both ways, with real-time bytes named", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)
      :ok = Machine.jog_stop(m)

      texts = for e <- Machine.console(m), do: {e.dir, e.text}
      assert {:out, "$X"} in texts
      assert {:in, "ok"} in texts
      assert {:out, "$J=G91 G21 X1.000 F1200"} in texts
      assert {:out, "0x85 jog cancel"} in texts
      assert_received {:machine_console, %{dir: :out, text: "$X"}}
    end

    test "status polls stream on their own topic and stay out of history", %{m: m, topic: topic} do
      connect(m, "Idle", {0, 0})
      refute_receive {:machine_console, %{kind: :poll}}, 250

      Machine.subscribe_polls(topic)
      assert_receive {:machine_console, %{kind: :poll, dir: :out, text: "? status"}}, 300
      report(m, "Idle", {1, 0})
      assert_receive {:machine_console, %{kind: :poll, dir: :in, text: "<Idle|" <> _}}

      refute Enum.any?(Machine.console(m), &(&1.kind == :poll))
    end

    test "history keeps the newest 200" do
      console =
        Enum.reduce(1..250, CNC.Machine.Console.new(), fn i, c ->
          CNC.Machine.Console.push(c, CNC.Machine.Console.entry(:out, :line, "L#{i}"))
        end)

      list = CNC.Machine.Console.to_list(console)
      assert length(list) == 200
      assert {hd(list).text, List.last(list).text} == {"L51", "L250"}
    end
  end

  describe "terminal (send_raw)" do
    setup do
      m = start_machine({CNC.ScriptedLink, test: self()}, "raw-#{System.unique_integer()}")
      assert_receive {:scripted_link, _fake, ^m}
      %{m: m}
    end

    test "passes lines through and tracks their acks", %{m: m} do
      idle(m)
      assert :ok = Machine.send_raw(m, "  $G  ")
      assert_receive {:line, "$G"}
      assert Machine.status(m).awaiting_ack == 1
      send(m, {:link, :line, "error:20"})
      assert %State{awaiting_ack: 0, last_error: {:error, 20}} = Machine.status(m)
    end

    test "$x unlocks through the normal path", %{m: m} do
      connect(m, "Alarm", {0, 0})
      assert :ok = Machine.send_raw(m, "$x")
      assert_receive {:line, "$X"}
      ok(m)
      assert Machine.status(m).state == :idle
    end

    test "a setting write re-reads settings, so travel follows", %{m: m} do
      idle(m)
      :ok = Machine.send_raw(m, "$130=500")
      assert_receive {:line, "$130=500"}
      ok(m)
      assert_receive {:line, "$$"}

      for l <- ["$130=500.000", "$131=1250.000", "$132=100.000", "ok"],
          do: send(m, {:link, :line, l})

      assert %State{travel: {{+0.0, 500.0}, _, _}, travel_source: :controller} = Machine.status(m)
    end

    test "?, ! and ~ go out as real-time bytes, not lines", %{m: m} do
      idle(m)

      for {typed, byte} <- [{"?", ??}, {"!", ?!}, {"~", ?~}] do
        assert :ok = Machine.send_raw(m, typed)
        assert_receive {:rt, ^byte}
      end

      refute_received {:line, _}
      assert Machine.status(m).awaiting_ack == 0
    end

    test "refused while jogging, and for blank or multi-line input", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)
      assert Machine.send_raw(m, "$$") == {:error, {:invalid_state, :jogging}}
      assert Machine.send_raw(m, "   ") == {:error, :invalid_line}
      assert Machine.send_raw(m, "G0 X1\nG0 X2") == {:error, :invalid_line}
    end
  end

  # Against the in-process simulator, end to end.
end
