defmodule CNC.Link.FakeSim.ModelTest do
  use ExUnit.Case, async: true

  alias CNC.Grbl.{Command, Realtime, Response}
  alias CNC.Link.FakeSim.Model

  # 600 mm/min = 10 mm/s = 0.01 mm/ms
  @feed 600

  defp idle(opts \\ []) do
    {m, _} = Model.new(opts) |> Model.line("$X")
    m
  end

  defp line(m, l), do: Model.line(m, l)
  defp jog(m, delta, feed \\ @feed), do: Model.line(m, Command.jog(delta, feed))
  defp rt(m, byte), do: Model.realtime(m, byte)

  defp status(m) do
    {_, [line]} = rt(m, Realtime.status())
    {:status, status} = Response.parse(line)
    status
  end

  defp assert_pos(m, {x, y, z}) do
    {a, b, c} = m.pos
    assert_in_delta a, x, 1.0e-9
    assert_in_delta b, y, 1.0e-9
    assert_in_delta c, z, 1.0e-9
  end

  test "boots into alarm with banner and unlock hint" do
    {m, lines} = Model.new() |> Model.boot()
    assert m.state == :alarm

    assert Enum.map(lines, &Response.parse/1) == [
             {:banner, "Grbl 1.1h ['$' for help]"},
             {:msg, "'$H'|'$X' to unlock"}
           ]
  end

  test "$X unlocks" do
    {m, lines} = Model.new() |> line("$X")
    assert m.state == :idle
    assert lines == ["[MSG:Caution: Unlocked]", "ok"]
    assert {_, ["ok"]} = line(m, "$X")
  end

  test "jog is rejected in alarm" do
    {m, lines} = Model.new() |> jog({10, 0, 0})
    assert {m.state, lines} == {:alarm, ["error:8"]}
  end

  test "jog integrates position at the commanded feed" do
    {m, ["ok"]} = idle() |> jog({10, 0, 0})
    assert m.state == :jog

    {m, []} = Model.advance(m, 500)
    assert_pos(m, {5.0, 0.0, 0.0})
    assert %{state: :jog, feed: 600.0} = status(m)

    {m, []} = Model.advance(m, 600)
    assert_pos(m, {10.0, 0.0, 0.0})
    assert %{state: :idle, feed: +0.0, mpos: {10.0, +0.0, +0.0}} = status(m)
  end

  test "queued jogs chain, carrying leftover time into the next segment" do
    {m, ["ok"]} = idle() |> jog({10, 0, 0})
    {m, ["ok"]} = jog(m, {0, 10, 0})
    assert %{buffer: {13, 128}} = status(m)

    {m, []} = Model.advance(m, 1500)
    assert_pos(m, {10.0, 5.0, 0.0})
    assert m.state == :jog
  end

  test "diagonal moves at path speed" do
    {m, ["ok"]} = idle() |> jog({30, 40, 0})
    {m, []} = Model.advance(m, 1000)
    assert_pos(m, {6.0, 8.0, 0.0})
  end

  test "feed is clamped to max_feed" do
    {m, ["ok"]} = idle(max_feed: 60.0) |> jog({10, 0, 0}, 6000)
    {m, []} = Model.advance(m, 1000)
    assert_pos(m, {1.0, 0.0, 0.0})
  end

  describe "soft limits" do
    test "jog beyond travel is error:15 and not queued" do
      {m, lines} = idle() |> jog({-1, 0, 0})
      assert lines == ["error:15"]
      assert m.state == :idle
    end

    test "checked against the end of the queue, not the current position" do
      m = idle(pos: {1240.0, 0.0, 0.0})
      {m, ["ok"]} = jog(m, {5, 0, 0})
      {_m, lines} = jog(m, {6, 0, 0})
      assert lines == ["error:15"]
    end
  end

  test "jog cancel and feed hold both stop and flush the queue" do
    for byte <- [Realtime.jog_cancel(), Realtime.feed_hold()] do
      {m, ["ok"]} = idle() |> jog({10, 0, 0})
      {m, ["ok"]} = jog(m, {10, 0, 0})
      {m, []} = Model.advance(m, 100)
      {m, []} = rt(m, byte)
      assert {m.state, :queue.len(m.queue)} == {:idle, 0}
      assert_pos(m, {1.0, 0.0, 0.0})
    end
  end

  test "feed hold from Idle suspends into Hold:0; cycle start or a reset releases it" do
    {m, []} = rt(idle(), Realtime.feed_hold())
    assert m.state == :hold
    {_, [report]} = rt(m, Realtime.status())
    assert report =~ ~r/^<Hold:0\|/
    assert {_, ["error:8"]} = jog(m, {10, 0, 0})

    {m2, []} = rt(m, Realtime.resume())
    assert m2.state == :idle

    {m3, _} = rt(m, Realtime.reset())
    assert m3.state == :idle
  end

  describe "G-code (jobs)" do
    test "moves run at their feed, in work coordinates, and end Idle" do
      m = idle()
      {m, ["ok"]} = line(m, "G10 L2 P1 X100 Y50 Z-20")
      {m, ["ok"]} = line(m, "G21 G90")
      {m, ["ok"]} = line(m, "G0 X10 Y0")
      {m, ["ok"]} = line(m, "G1 Z-5 F600")
      assert m.state == :run
      assert status(m).state == :run

      {m, []} = Model.advance(m, 60_000)
      assert m.state == :idle
      # work (10, 0, -5) at the offset (100, 50, -20)
      assert_pos(m, {110.0, 50.0, -25.0})
    end

    test "relative moves, inches, and an arc that ends where it says" do
      m = idle(pos: {100.0, 100.0, 0.0})
      {m, ["ok"]} = line(m, "G91 G1 X10 F1000")
      {m, ["ok"]} = line(m, "G20 X1")
      {m, ["ok"]} = line(m, "G90 G21 G2 X130 Y100 I10 J0")
      {m, []} = Model.advance(m, 600_000)
      assert_pos(m, {130.0, 100.0, 0.0})
    end

    test "a line is acked only once its moves fit in the planner" do
      m = idle()
      m = Enum.reduce(1..15, m, fn i, m -> elem(line(m, "G1 X#{i} F600"), 0) end)
      assert {m, []} = line(m, "G1 X20 F600")
      assert {m, []} = line(m, "G1 X21 F600")
      # A move finishes: one waiting line goes in, with its ok
      {m, oks} = Model.advance(m, 150)
      assert "ok" in oks
      assert :queue.len(m.waiting) <= 1
    end

    test "hold stops motion and keeps the rest; resume carries on; reset while running locks" do
      m = idle()
      {m, ["ok"]} = line(m, "G1 X100 F600")
      {m, []} = Model.advance(m, 1000)
      {m, []} = rt(m, Realtime.feed_hold())
      assert status(m).state == :hold
      {held, []} = Model.advance(m, 1000)
      assert held.pos == m.pos

      {m, []} = rt(held, Realtime.resume())
      assert m.state == :run
      {m, lines} = rt(m, Realtime.reset())
      assert "ALARM:3" in lines
      assert m.state == :alarm
    end

    test "errors like Grbl: locked, no feed, outside the travel; feed override" do
      assert {_, ["error:9"]} = line(Model.new(), "G1 X1 F100")
      assert {_, ["error:22"]} = line(idle(), "G1 X1")
      assert {m, ["ALARM:2"]} = line(idle(), "G0 X5000")
      assert m.state == :alarm

      m = idle()
      {m, []} = rt(m, 0x91)
      assert status(m).overrides == {110, 100, 100}
    end
  end

  test "homing acks only when complete, at the origin" do
    m = idle(pos: {100.0, 100.0, 0.0}, homing_ms: 300)
    {m, []} = line(m, "$H")
    assert status(m).state == :home
    assert {_, ["error:8"]} = jog(m, {1, 0, 0})

    {m, []} = Model.advance(m, 200)
    {m, ["ok"]} = Model.advance(m, 100)
    assert m.state == :idle
    assert_pos(m, {0.0, 0.0, 0.0})
  end

  describe "soft reset" do
    test "while jogging raises ALARM:3 and needs unlocking" do
      {m, ["ok"]} = idle() |> jog({10, 0, 0})
      {m, lines} = rt(m, Realtime.reset())
      assert m.state == :alarm
      assert ["ALARM:3", "Grbl" <> _, "[MSG:" <> _] = lines
    end

    test "while homing raises ALARM:6" do
      {m, []} = idle() |> line("$H")
      assert {%{state: :alarm}, ["ALARM:6" | _]} = rt(m, Realtime.reset())
    end

    test "while idle just reboots" do
      {m, lines} = idle() |> rt(Realtime.reset())
      assert m.state == :idle
      assert ["Grbl" <> _] = lines
    end
  end

  test "injected alarm stops motion" do
    {m, ["ok"]} = idle() |> jog({10, 0, 0})
    {m, ["ALARM:1"]} = Model.alarm(m, 1)
    assert {m.state, :queue.len(m.queue)} == {:alarm, 0}
  end

  describe "settings" do
    test "$$ lists travel lengths" do
      assert {_, ["$130=1250.000", "$131=1250.000", "$132=100.000", "ok"]} =
               Model.new() |> line("$$")
    end

    test "$13x= sets travel, and soft limits follow" do
      {m, ["ok"]} = idle() |> line("$130=20")
      {m, ["ok"]} = line(m, "$132=50.5")
      assert m.travel == {{0.0, 20.0}, {0.0, 1250.0}, {-50.5, 0.0}}
      assert {_, ["error:15"]} = jog(m, {21, 0, 0})
      assert {_, ["ok"]} = jog(m, {19, 0, 0})
    end

    test "rejects bad values and busy states" do
      m = idle()
      assert {_, ["error:4"]} = line(m, "$130=-5")
      assert {_, ["error:2"]} = line(m, "$130=abc")
      {m, ["ok"]} = jog(m, {1, 0, 0})
      assert {_, ["error:8"]} = line(m, "$$")
      assert {_, ["error:20"]} = line(m, "$130=5")
    end
  end

  describe "work offset (G54)" do
    test "G10 L20 P1 makes the current position the given work position" do
      m = idle(pos: {100.0, 50.0, -10.0})
      {m, ["ok"]} = line(m, "G10 L20 P1 X0 Y0")
      assert m.wco == {100.0, 50.0, +0.0}
      {m, ["ok"]} = line(m, "G10 L20 P1 Z5")
      assert m.wco == {100.0, 50.0, -15.0}
    end

    test "WCO is reported right after a change, then every 10th report" do
      m = idle(pos: {1.0, 2.0, 3.0})
      {m, ["ok"]} = line(m, "G10 L20 P1 X0")
      {m, [first]} = rt(m, Realtime.status())
      assert first =~ "WCO:1.000,0.000,0.000"

      {_m, lines} =
        Enum.reduce(1..10, {m, []}, fn _, {m, acc} ->
          {m, [l]} = rt(m, Realtime.status())
          {m, acc ++ [l]}
        end)

      assert Enum.count(lines, &(&1 =~ "WCO:")) == 1
      assert List.last(lines) =~ "WCO:"
      assert {:status, %{wpos: {+0.0, 2.0, 3.0}}} = Response.parse(first)
    end

    test "rejected while moving, and for bad words" do
      {m, ["ok"]} = idle() |> jog({10, 0, 0})
      assert {_, ["error:8"]} = line(m, "G10 L20 P1 X0")
      assert {_, ["error:2"]} = line(idle(), "G10 L20 P1 Xq")
      assert {_, ["error:26"]} = line(idle(), "G10 L20 P1")
    end
  end

  test "$ lists the commands it understands" do
    assert {_, ["[HLP:" <> _, "ok"]} = Model.new() |> line("$")
  end

  test "malformed or unsupported lines" do
    m = idle()
    assert {_, ["error:20"]} = line(m, "G28")
    assert {_, ["error:20"]} = line(m, "$J=G90 G21 X1 F100")
    assert {_, ["error:22"]} = line(m, "$J=G91 G21 X1")
    assert {_, ["error:2"]} = line(m, "$J=G91 G21 Xabc F100")
  end
end
