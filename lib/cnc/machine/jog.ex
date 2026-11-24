defmodule CNC.Machine.Jog do
  @moduledoc """
  Pure jog maths: tiers, per-tick increments, the run-ahead bound and the
  travel clamp.

  Continuous jogging sends one short relative move per tick (`dt`). Each
  increment is `speed × dt` long at `speed` feed, so it takes exactly `dt` to
  execute and the controller never holds more than a few ticks of motion.

  Z has its own, slower tiers. A move with a Z component is slowed so Z never
  exceeds its tier speed; X/Y-only moves run at the X/Y tier speed, with
  diagonals normalised so path speed equals the tier speed.
  """

  @tiers %{fine: 5, normal: 20, fast: 50}
  @z_tiers %{fine: 1, normal: 5, fast: 10}
  @dt_ms 50
  @max_ahead 4
  @inset 0.001

  @type tier :: :fine | :normal | :fast
  @type vector :: {-1..1, -1..1, -1..1}

  def tiers, do: Map.keys(@tiers)
  def dt_ms, do: @dt_ms
  def max_in_flight, do: @max_ahead

  @doc "X/Y tier speed in mm/s."
  def speed(tier), do: Map.fetch!(@tiers, tier)

  @doc "Z tier speed in mm/s."
  def z_speed(tier), do: Map.fetch!(@z_tiers, tier)

  @doc "One tick's move for a held-key vector: `{{dx, dy, dz}, feed_mm_min}`."
  def increment({dx, dy, dz}, tier) do
    norm = :math.sqrt(dx * dx + dy * dy + dz * dz)
    {ux, uy, uz} = {dx / norm, dy / norm, dz / norm}
    v = path_speed(uz, tier)
    len = v * @dt_ms / 1000
    {{ux * len, uy * len, uz * len}, v * 60}
  end

  @doc "A single step of `mm` along each non-zero axis of `vector`."
  def step({dx, dy, dz}, mm, tier) do
    feed = if dz != 0, do: z_speed(tier), else: speed(tier)
    {{dx * mm, dy * mm, dz * mm}, feed * 60}
  end

  # Path speed such that the Z component stays within the Z tier.
  defp path_speed(uz, tier) do
    v = speed(tier)
    if abs(uz) * v > z_speed(tier), do: z_speed(tier) / abs(uz), else: v
  end

  @doc """
  True if another increment of length `len` may be sent: the commanded end
  point must stay within `max_in_flight` increments of the last reported
  position.
  """
  def room_ahead?(target, mpos, len),
    do: distance(target, mpos) + len <= @max_ahead * len + 1.0e-6

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

  def magnitude({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)

  defp distance({a, b, c}, {x, y, z}), do: :math.sqrt((x - a) ** 2 + (y - b) ** 2 + (z - c) ** 2)
end
