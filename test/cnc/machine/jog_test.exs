defmodule CNC.Machine.JogTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CNC.Machine.Jog

  @travel {{0.0, 100.0}, {0.0, 100.0}, {-10.0, 0.0}}

  describe "clamp/3" do
    test "inside travel: unchanged, rounded to 3 decimals" do
      assert Jog.clamp({50.0, 50.0, 0.0}, {1.23456, -2.0, 0.0}, @travel) == {1.235, -2.0, 0.0}
    end

    test "stops a micron inside the edge" do
      assert Jog.clamp({99.5, 0.5, -5.0}, {1.0, -1.0, 0.0}, @travel) == {0.499, -0.499, 0.0}
    end

    test "slides along an edge on a diagonal" do
      assert Jog.clamp({99.999, 50.0, -5.0}, {0.7, 0.7, 0.0}, @travel) == {0.0, 0.7, 0.0}
    end

    test "outside travel: never yanks back in, never moves an idle axis" do
      assert Jog.clamp({150.0, 50.0, -5.0}, {1.0, 0.0, 0.0}, @travel) == {0.0, 0.0, 0.0}
      assert Jog.clamp({150.0, 50.0, -5.0}, {-1.0, 0.0, 0.0}, @travel) == {-1.0, 0.0, 0.0}
      assert Jog.clamp({150.0, 50.0, -5.0}, {0.0, 1.0, 0.0}, @travel) == {0.0, 1.0, 0.0}
    end

    property "ends inside travel, or no further out than it started" do
      check all from <- tuple({coord(), coord(), float(min: -20.0, max: 10.0)}),
                delta <- tuple({step(), step(), step()}) do
        to = Jog.add(from, Jog.clamp(from, delta, @travel))

        for {p, q, {lo, hi}} <- zip3(from, to, @travel) do
          assert q >= min(lo, p) - 1.0e-9
          assert q <= max(hi, p) + 1.0e-9
        end
      end
    end
  end

  test "increment normalises diagonals to tier speed" do
    {{dx, dy, +0.0}, 3000} = Jog.increment({1, -1}, :fast)
    assert_in_delta :math.sqrt(dx * dx + dy * dy), 2.5, 1.0e-9
  end

  defp coord, do: float(min: -20.0, max: 120.0)
  defp step, do: float(min: -5.0, max: 5.0)

  defp zip3(a, b, c), do: Enum.zip([Tuple.to_list(a), Tuple.to_list(b), Tuple.to_list(c)])
end
