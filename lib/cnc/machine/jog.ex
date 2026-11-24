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

  def add({a, b, c}, {x, y, z}), do: {a + x, b + y, c + z}

  defp xy_distance({a, b, _}, {x, y, _}), do: :math.sqrt((x - a) ** 2 + (y - b) ** 2)
end
