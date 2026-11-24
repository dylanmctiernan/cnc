defmodule CNC.Grbl.CommandTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CNC.Grbl.{Command, Realtime}

  doctest Command

  test "simple commands" do
    assert Command.unlock() == "$X"
    assert Command.home() == "$H"
    assert Command.settings() == "$$"
  end

  test "real-time bytes" do
    assert {Realtime.status(), Realtime.feed_hold(), Realtime.resume()} == {??, ?!, ?~}
    assert {Realtime.reset(), Realtime.jog_cancel()} == {0x18, 0x85}
  end

  describe "jog/2" do
    test "omits zero axes and fixes decimals" do
      assert Command.jog({0, 2, 0}, 300) == "$J=G91 G21 Y2.000 F300"
      assert Command.jog({-0.1, 0.25, 0.0}, 1200.4) == "$J=G91 G21 X-0.100 Y0.250 F1200"
    end

    test "treats sub-micron moves as zero" do
      assert Command.jog({0.0004, -0.0004, 1}, 60) == "$J=G91 G21 Z1.000 F60"
    end

    test "rejects a zero vector and non-positive feed" do
      assert_raise ArgumentError, fn -> Command.jog({0, 0.0001, 0}, 100) end
      assert_raise FunctionClauseError, fn -> Command.jog({1, 0, 0}, 0) end
    end

    property "round-trips axis values at 3 decimals and omits zeros" do
      check all delta <- {axis(), axis(), axis()},
                delta != {0, 0, 0},
                feed <- integer(1..6000) do
        line = Command.jog(scale(delta), feed)

        assert "$J=G91 G21 " <> rest = line
        words = String.split(rest, " ")
        assert List.last(words) == "F#{feed}"

        parsed =
          for <<axis::binary-1, value::binary>> <- Enum.drop(words, -1),
              into: %{},
              do: {axis, String.to_float(value)}

        expected =
          for {axis, k} <- Enum.zip(~w(X Y Z), Tuple.to_list(delta)),
              k != 0,
              into: %{},
              do: {axis, k / 1000}

        assert parsed == expected
      end
    end
  end

  # Axis deltas in thousandths of a mm (±1250 mm), so values are exact at 3 decimals.
  defp axis, do: one_of([constant(0), integer(-1_250_000..1_250_000)])
  defp scale(delta), do: delta |> Tuple.to_list() |> Enum.map(&(&1 / 1000)) |> List.to_tuple()
end
