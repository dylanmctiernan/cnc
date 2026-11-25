defmodule CNCApp.Bit do
  @moduledoc """
  The bit in the spindle: its cutting diameter and type (a flat end mill,
  a ball nose, or a V-bit and its angle).

  Optional: with none set, checks use the toolpath alone (the centre of the
  bit). With one, they use where the cutter actually reaches, the path plus
  its radius: how far past the stock's edges it goes is how close it comes
  to the clamps (`CNCApp.Stock.issues/3`). And the 3D view draws it.

  Kept in the app's database (one spindle, one bit in it at a time); every
  open screen hears a change (`subscribe/1`).
  """
  use Boundary, top_level?: true, deps: [], exports: []

  @key :bit
  @pubsub CNC.PubSub
  @kinds [:flat, :ball, :v]
  @angles [30, 60, 90, 120]

  @type kind :: :flat | :ball | :v
  @type t :: %{diameter: float, kind: kind, angle: pos_integer | nil}

  @doc "The bit, or nil when none is set."
  @spec get(GenServer.server()) :: t | nil
  def get(db), do: CubDB.get(db, @key)

  @doc """
  Set the bit: `%{diameter:, kind:}` (and `angle:` in degrees for a V-bit:
  #{inspect(@angles)}). Diameter in mm, more than 0, at most 100. Every
  screen hears `{:bit, bit}`.
  """
  @spec put(GenServer.server(), map) :: {:ok, t} | {:error, :invalid}
  def put(db, %{diameter: d, kind: kind} = bit) do
    angle = if kind == :v, do: Map.get(bit, :angle), else: nil

    if is_number(d) and d > 0 and d <= 100 and kind in @kinds and
         (kind != :v or angle in @angles) do
      bit = %{diameter: d * 1.0, kind: kind, angle: angle}
      :ok = CubDB.put(db, @key, bit)
      broadcast(db, bit)
      {:ok, bit}
    else
      {:error, :invalid}
    end
  end

  def put(_db, _bit), do: {:error, :invalid}

  @doc "No bit: checks use the toolpath alone."
  def clear(db) do
    :ok = CubDB.delete(db, @key)
    broadcast(db, nil)
    :ok
  end

  @doc "Hear changes: `{:bit, bit | nil}`."
  def subscribe(db), do: Phoenix.PubSub.subscribe(@pubsub, topic(db))

  @doc "The kinds of bit."
  def kinds, do: @kinds

  @doc "A V-bit's included angles, in degrees."
  def angles, do: @angles

  @doc """
  How far the cutter reaches from the toolpath, mm: its radius (0 with no
  bit).

      iex> CNCApp.Bit.radius(%{diameter: 6.35, kind: :flat, angle: nil})
      3.175
      iex> CNCApp.Bit.radius(nil)
      0.0
  """
  def radius(nil), do: 0.0
  def radius(%{diameter: d}), do: d / 2

  defp broadcast(db, bit), do: Phoenix.PubSub.broadcast(@pubsub, topic(db), {:bit, bit})
  defp topic(db), do: "bit:#{inspect(db)}"
end
