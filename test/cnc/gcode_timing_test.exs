defmodule CNC.GCode.TimingTest do
  use ExUnit.Case, async: true

  alias CNC.GCode
  alias CNC.GCode.Timing

  @opts [max_rate: {3000.0, 3000.0, 600.0}, accel: {500.0, 500.0, 100.0}, junction: 0.01]

  defp seconds(text, opts \\ @opts), do: GCode.parse(text, opts).seconds

  test "a long straight cut: its length over its feed, plus getting up to speed and back" do
    # 300 mm at 20 mm/s; 0.04 s up, 0.04 s down (0.4 mm each)
    assert_in_delta seconds("G0 X0 Y0\nG1 X300 F1200"), 0.08 + 299.2 / 20, 1.0e-6
  end

  test "a rapid in Z runs at Z's rate and acceleration, not X/Y's" do
    # 50 mm at 10 mm/s (600 mm/min), accel 100: 0.1 s up/down, 0.5 mm each
    assert_in_delta seconds("G0 X0 Y0\nG0 Z-50"), 0.2 + 49.0 / 10, 1.0e-6
  end

  test "a straight line split into pieces takes as long as one piece" do
    one = seconds("G0 X0 Y0\nG1 X100 F1200")
    many = seconds("G0 X0 Y0\n" <> Enum.map_join(1..100, "\n", &"G1 X#{&1} F1200"))
    assert_in_delta many, one, 1.0e-6
  end

  test "corners slow it down; a zigzag of short moves takes far longer than length / feed" do
    zigzag =
      "G0 X0 Y0\nG1 F3000\n" <> Enum.map_join(1..200, "\n", &"X#{rem(&1, 2) * 2} Y#{&1 * 0.5}")

    p = GCode.parse(zigzag, @opts)
    naive = p.cut_mm / 50
    assert p.seconds > naive * 1.5
  end

  test "the timeline: cumulative by line, split into feed, rapid and fixed" do
    p = GCode.parse("G0 X0 Y0\nG1 X100 F600\nG0 X0\nG4 P2", @opts)
    t = p.timeline

    assert Timing.at(t, 1) == {0.0, 0.0, 0.0}
    {f2, r2, x2} = Timing.at(t, 2)
    assert_in_delta f2, 99.8 / 10, 1.0e-6
    assert r2 == 0.0
    assert_in_delta x2, 0.04, 1.0e-6

    {f3, r3, _} = Timing.at(t, 3)
    assert f3 == f2
    assert r3 > 0
    # Past the end: the whole program; the dwell counted as fixed
    assert Timing.at(t, 99) == Timing.total(t)
    {_, _, x4} = Timing.total(t)
    assert x4 > 2.0
  end

  test "overrides scale their own part: feed the cutting, rapids the rapids" do
    t = GCode.parse("G0 X0 Y0\nG1 X100 F600\nG0 X0", @opts).timeline
    {f, r, x} = Timing.total(t)
    assert_in_delta Timing.seconds({f, r, x}, 50, 100), 2 * f + r + x, 1.0e-9
    assert_in_delta Timing.seconds({f, r, x}, 100, 25), f + 4 * r + x, 1.0e-9
  end

  test "an arc counts once per line, however many chords it's drawn with" do
    t = GCode.parse("G0 X10 Y0\nG3 X-10 Y0 I-10 J0 F600\nG1 X-20", @opts).timeline
    {f2, _, _} = Timing.at(t, 2)
    # Half a circle of radius 10 at 10 mm/s: ~3.14 s
    assert_in_delta f2, :math.pi(), 0.1
    # Two lines in the timeline; the arc is many planner blocks
    assert byte_size(t) == 2 * 32
    # Grbl's split at 0.002 mm: floor(½·π·10 / √(0.002·19.998)) = 78
    assert Timing.blocks(t, 2) == 78
    assert Timing.blocks(t, 3) == 1
  end
end
