defmodule CNC.GCodeTest do
  use ExUnit.Case, async: true

  alias CNC.GCode
  alias CNC.GCode.Program

  defp parse(text, opts \\ []), do: GCode.parse(text, opts)
  # Packed as float32: compare at a micron.
  defp ends(p), do: Enum.map(GCode.segments(p), fn {kind, _, to, _} -> {kind, round3(to)} end)
  defp round3({x, y, z}), do: {Float.round(x, 3), Float.round(y, 3), Float.round(z, 3)}
  defp kinds(%Program{warnings: ws}), do: Enum.map(ws, & &1.kind)

  test "straight moves, modal motion, comments, line numbers" do
    p =
      parse("""
      %
      (pocket) G21 G90
      N10 G0 X0 Y0 Z5 ; start
      G1 Z-1 F300
      X10
      Y10 (corner)
      G0 Z5
      M30
      G1 X99
      %
      """)

    assert ends(p) == [
             {:feed, {0.0, 0.0, -1.0}},
             {:feed, {10.0, 0.0, -1.0}},
             {:feed, {10.0, 10.0, -1.0}},
             {:rapid, {10.0, 10.0, 5.0}}
           ]

    # The first move goes from an unknown start: it sets the position but
    # isn't drawn. Everything after M30 is ignored.
    # plunge 6 + 10 + 10
    assert p.cut_mm == 26.0
    assert p.rapid_mm == 6.0
    assert p.cut_bounds == {{0.0, 10.0}, {0.0, 10.0}, {-1.0, 5.0}}
    assert p.bounds == {{0.0, 10.0}, {0.0, 10.0}, {-1.0, 5.0}}
    assert p.warnings == []
  end

  test "nothing is drawn until X and Y are both known" do
    p = parse("G0 Z5\nG0 X10\nG1 Z-1 F100\nG0 Y4\nG1 X0")
    # Only the moves after Y is first given are drawn.
    assert ends(p) == [{:feed, {0.0, 4.0, -1.0}}]
  end

  test "relative distance and inches" do
    p = parse("G20 G91\nG0 X0 Y0\nG1 X1 F10\nX1")
    assert [{:feed, {25.4, +0.0, +0.0}}, {:feed, {50.8, +0.0, +0.0}}] = ends(p)
    assert :inches in kinds(p)
  end

  test "time: feeds at their F, rapids at the max rate, with acceleration; dwells" do
    p = parse("G0 X0 Y0\nG1 X100 F600\nG0 X0\nG4 P2", max_rate: {6000.0, 6000.0, 1200.0})
    # 100 mm at 10 mm/s, 0.02 s up and down at 500 mm/s² (0.1 mm each):
    # 10.02 s. It reverses, so stops. 100 mm rapid at 100 mm/s: 0.2 s up
    # and down (10 mm each), 80 mm at speed: 1.2 s. Dwell 2 s.
    assert_in_delta p.seconds, 10.02 + 1.2 + 2.0, 1.0e-6
  end

  test "a quarter arc (G3, I/J) ends exactly and stays on the circle" do
    p = parse("G0 X10 Y0\nG3 X0 Y10 I-10 J0 F100")
    [{:feed, start, _, 2} | _] = feeds = Enum.filter(GCode.segments(p), &(elem(&1, 0) == :feed))
    assert round3(start) == {10.0, 0.0, 0.0}
    {:feed, _, last, _} = List.last(feeds)
    assert round3(last) == {0.0, 10.0, 0.0}

    for {_, {x, y, _}, _, _} <- feeds, do: assert_in_delta(:math.sqrt(x * x + y * y), 10, 1.0e-5)
    assert length(feeds) >= 4
    # Chords run inside the arc: a little shorter than the true length.
    assert_in_delta p.cut_mm, :math.pi() * 10 / 2, 0.1
  end

  test "G2 goes clockwise, G3 anticlockwise" do
    cw = parse("G0 X10 Y0\nG2 X-10 Y0 I-10 J0 F100")
    ccw = parse("G0 X10 Y0\nG3 X-10 Y0 I-10 J0 F100")
    {_, _, {_, y_cw, _}, _} = Enum.at(GCode.segments(cw), 3)
    {_, _, {_, y_ccw, _}, _} = Enum.at(GCode.segments(ccw), 3)
    assert y_cw < 0 and y_ccw > 0
  end

  test "full circle when the arc ends where it starts" do
    p = parse("G0 X10 Y0\nG2 X10 Y0 I-10 J0 F100")
    assert_in_delta p.cut_mm, 2 * :math.pi() * 10, 0.3
  end

  test "R-format arcs, both the short and the long way round" do
    short = parse("G0 X10 Y0\nG3 X0 Y10 R10 F100")
    long = parse("G0 X10 Y0\nG3 X0 Y10 R-10 F100")
    assert_in_delta short.cut_mm, :math.pi() * 10 / 2, 0.1
    assert_in_delta long.cut_mm, :math.pi() * 10 * 3 / 2, 0.3
  end

  test "helix: Z moves linearly along the arc" do
    p = parse("G0 X10 Y0 Z0\nG2 X10 Y0 Z-2 I-10 J0 F100")
    {_, _, {_, _, z_mid}, _} = Enum.at(GCode.segments(p), div(length(GCode.segments(p)), 2))
    assert z_mid < -0.5 and z_mid > -1.5
    assert p.cut_bounds |> elem(2) == {-2.0, 0.0}
  end

  test "tools, spindle and things the preview can't show are reported" do
    p =
      parse("""
      T1 M6
      S12000 M3
      G0 X0 Y0
      G53 G0 Z0
      G55
      G38.2 Z-10 F50
      G81 X1 Y1 Z-2 R1
      G1 X5 F100 Q3
      T2 M6
      """)

    assert p.tools == [1, 2]
    assert p.max_spindle == 12000.0
    kinds = kinds(p)
    assert :machine_coordinates in kinds
    assert :other_work_offset in kinds
    assert :probing in kinds
    assert :canned_cycle in kinds
    assert {:unknown_word, "Q"} in kinds
    assert %{line: 4, count: 1} = Enum.find(p.warnings, &(&1.kind == :machine_coordinates))
  end

  test "a feed move without a feed rate is flagged" do
    assert :no_feed in kinds(parse("G0 X0 Y0\nG1 X10"))
  end

  test "unparseable lines are flagged, the rest still parses" do
    p = parse("G0 X0 Y0\nthis is not gcode\nG1 X5 F100")
    assert %{kind: :bad_line, line: 2} = hd(p.warnings)
    assert List.last(ends(p)) == {:feed, {5.0, 0.0, 0.0}}
  end

  test "empty input" do
    assert %Program{path: "", segment_count: 0, bounds: nil, lines: 0} = parse("")
  end
end
