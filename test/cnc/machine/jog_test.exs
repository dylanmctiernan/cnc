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
    {{dx, dy, +0.0}, feed} = Jog.increment({1, -1, 0}, :fast)
    assert_in_delta :math.sqrt(dx * dx + dy * dy), 2.5, 1.0e-9
    assert_in_delta feed, 3000, 1.0e-6
  end

  test "analog: speed is proportional to deflection" do
    {{dx, +0.0, +0.0}, feed} = Jog.increment({0.5, 0, 0}, :normal)
    assert_in_delta dx, 0.5, 1.0e-9
    assert_in_delta feed, 600, 1.0e-6

    {{dx, dy, +0.0}, _} = Jog.increment({0.3, 0.4, 0}, :normal)
    assert_in_delta :math.sqrt(dx * dx + dy * dy), 0.5, 1.0e-9
  end

  test "each axis keeps its own tier when combined" do
    {{dx, +0.0, dz}, _} = Jog.increment({1, 0, 1}, :fast)
    assert_in_delta dx, 2.5, 1.0e-9
    assert_in_delta dz, 0.5, 1.0e-9
  end

  test "Z-only increments use the Z tier" do
    assert {{+0.0, +0.0, dz}, 600.0} = Jog.increment({0, 0, 1}, :fast)
    assert_in_delta dz, 0.5, 1.0e-9
  end

  property "no axis group exceeds its tier speed; feed matches the move" do
    check all v <-
                tuple(
                  {float(min: -1.0, max: 1.0), float(min: -1.0, max: 1.0),
                   float(min: -1.0, max: 1.0)}
                ),
              v != {0.0, 0.0, 0.0},
              tier <- member_of([:fine, :normal, :fast]) do
      {{dx, dy, dz}, feed} = Jog.increment(v, tier)
      assert abs(dz) / Jog.dt_ms() * 1000 <= Jog.z_speed(tier) + 1.0e-9
      assert :math.sqrt(dx * dx + dy * dy) / Jog.dt_ms() * 1000 <= Jog.speed(tier) + 1.0e-9

      assert_in_delta Jog.magnitude(elem(Jog.increment(v, tier), 0)) / Jog.dt_ms() * 1000 * 60,
                      feed,
                      1.0e-6
    end
  end

  test "steps on Z use the Z tier feed" do
    assert Jog.step({0, 0, -1}, 10, :normal) == {{0, 0, -10}, 300}
    assert Jog.step({1, 0, 0}, 10, :normal) == {{10, 0, 0}, 1200}
  end

  defp coord, do: float(min: -20.0, max: 120.0)
  defp step, do: float(min: -5.0, max: 5.0)

  defp zip3(a, b, c), do: Enum.zip([Tuple.to_list(a), Tuple.to_list(b), Tuple.to_list(c)])
end
