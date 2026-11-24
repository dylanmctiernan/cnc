defmodule CNC.Machine.Jog do
  @moduledoc """
  Pure jog maths: tiers, per-tick increments, and the run-ahead bound.

  Continuous jogging sends one short relative move per tick (`dt`). Each
  increment is `speed × dt` long at `speed` feed, so it takes exactly `dt` to
  execute and the controller never holds more than a few ticks of motion.
  """

  @tiers %{fine: 5, normal: 20, fast: 50}
  @dt_ms 50
  @max_ahead 4
  @inset 0.001

  @type tier :: :fine | :normal | :fast
  @type vector :: {-1..1, -1..1}

  def tiers, do: Map.keys(@tiers)
  def dt_ms, do: @dt_ms
  def max_in_flight, do: @max_ahead

  @doc "Tier speed in mm/s."
  def speed(tier), do: Map.fetch!(@tiers, tier)

  @doc """
  One tick's move for a held-key vector: `{{dx, dy, dz}, feed_mm_min}`.
  Diagonals are normalised so path speed equals the tier speed.
  """
  def increment({dx, dy}, tier) do
    len = speed(tier) * @dt_ms / 1000
    norm = :math.sqrt(dx * dx + dy * dy)
    {{dx / norm * len, dy / norm * len, 0.0}, speed(tier) * 60}
  end

  @doc "A single step of `mm` along each non-zero axis of `vector`."
  def step({dx, dy}, mm, tier), do: {{dx * mm, dy * mm, 0.0}, speed(tier) * 60}

  @doc """
  True if another increment may be sent: the commanded end point must stay
  within `max_in_flight` increments of the last reported position.
  """
  def room_ahead?(target, mpos, tier) do
    len = speed(tier) * @dt_ms / 1000
    xy_distance(target, mpos) + len <= @max_ahead * len + 1.0e-6
  end

  @doc """
  Clamp a move from `from` so it stays inside `travel`
  (`{{x0, x1}, {y0, y1}, {z0, z1}}`), inset by a micron so 3-decimal rounding
  can't trip the controller's own soft limit. Deltas are rounded to 3
  decimals, as the controller will receive them.

  Per axis, a move may only go toward the box or stop at its edge: if `from`
  is already outside (e.g. unlocked without homing), clamping never yanks
  the axis back in, and an axis with no delta never moves.
  """
  def clamp(from, delta, travel) do
    [from, delta, travel]
    |> Enum.map(&Tuple.to_list/1)
    |> Enum.zip_with(fn [p, d, {lo, hi}] ->
      Float.round(clamp_axis(p, d, lo + @inset, hi - @inset) - p, 3)
    end)
    |> List.to_tuple()
  end

  defp clamp_axis(p, d, _lo, hi) when d > 0, do: min(p + d, max(hi, p))
  defp clamp_axis(p, d, lo, _hi) when d < 0, do: max(p + d, min(lo, p))
  defp clamp_axis(p, _d, _lo, _hi), do: p

  @doc "True if a (rounded) delta has no motion left in it."
  def zero?(delta), do: delta |> Tuple.to_list() |> Enum.all?(&(&1 == 0))

  def add({a, b, c}, {x, y, z}), do: {a + x, b + y, c + z}

  defp xy_distance({a, b, _}, {x, y, _}), do: :math.sqrt((x - a) ** 2 + (y - b) ** 2)
end
