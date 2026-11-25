defmodule CNCApp.Stock do
  @moduledoc """
  The stock on the machine: the piece being cut. Its size (width along X,
  depth along Y, thickness) and where the work zero is on it: the top of
  the front-left corner (the usual for a router: zero X/Y on the corner, Z
  on the surface) or the top of its centre (as some CAM setups do).

  Optional: with none set, nothing is checked against it. Kept in the
  app's database (one machine, one piece on it at a time), and every open
  screen hears a change (`subscribe/1`).

  With it, before Start: does the program stay on the stock, and does it
  cut deeper than the stock is thick (into the spoilboard)? See
  `issues/2`. And the views draw it where it sits.
  """
  use Boundary, top_level?: true, deps: [], exports: []

  @key :stock
  @pubsub CNC.PubSub
  @zeros [:front_left, :center]
  # Smaller than this past an edge or below the bottom isn't worth a word
  @tolerance 0.05

  @type zero :: :front_left | :center
  @type t :: %{width: float, depth: float, thickness: float, zero: zero}

  @doc "The stock, or nil when none is set."
  @spec get(GenServer.server()) :: t | nil
  def get(db), do: CubDB.get(db, @key)

  @doc """
  Set the stock: `%{width:, depth:, thickness:, zero:}`, sizes in mm
  (positive, at most 5000). Every screen hears `{:stock, stock}`.
  """
  @spec put(GenServer.server(), map) :: {:ok, t} | {:error, :invalid}
  def put(db, %{width: w, depth: d, thickness: t, zero: zero}) do
    if Enum.all?([w, d, t], &(is_number(&1) and &1 > 0 and &1 <= 5000)) and zero in @zeros do
      stock = %{width: w * 1.0, depth: d * 1.0, thickness: t * 1.0, zero: zero}
      :ok = CubDB.put(db, @key, stock)
      broadcast(db, stock)
      {:ok, stock}
    else
      {:error, :invalid}
    end
  end

  def put(_db, _stock), do: {:error, :invalid}

  @doc "No stock: nothing checked against it."
  def clear(db) do
    :ok = CubDB.delete(db, @key)
    broadcast(db, nil)
    :ok
  end

  @doc "Hear changes: `{:stock, stock | nil}`."
  def subscribe(db), do: Phoenix.PubSub.subscribe(@pubsub, topic(db))

  @doc "Where the work zero can be on the stock (always on its top)."
  def zeros, do: @zeros

  @doc """
  The stock as a box in work coordinates:
  `{{x0, x1}, {y0, y1}, {z0, z1}}`, its top at Z 0.

      iex> CNCApp.Stock.box(%{width: 300.0, depth: 200.0, thickness: 18.0, zero: :front_left})
      {{0.0, 300.0}, {0.0, 200.0}, {-18.0, 0.0}}
      iex> CNCApp.Stock.box(%{width: 300.0, depth: 200.0, thickness: 18.0, zero: :center})
      {{-150.0, 150.0}, {-100.0, 100.0}, {-18.0, 0.0}}
  """
  def box(%{width: w, depth: d, thickness: t, zero: :front_left}),
    do: {{0.0, w}, {0.0, d}, {-t, 0.0}}

  def box(%{width: w, depth: d, thickness: t, zero: :center}),
    do: {{-w / 2, w / 2}, {-d / 2, d / 2}, {-t, 0.0}}

  @doc """
  Where a program's cutting moves (`cut_bounds`, work coordinates) leave
  the stock: `[{:edge, :left | :right | :front | :back, mm} | {:through, mm}]`
  (`:through`: deeper than the stock is thick, into what's under it).
  Empty when they stay on it. Warnings, not refusals: an outside profile
  runs a bit's radius past the edge, a cut-out goes a little through.
  """
  def issues(nil, _stock), do: []
  def issues(_cut_bounds, nil), do: []

  def issues({{px0, px1}, {py0, py1}, {pz0, _}}, stock) do
    {{x0, x1}, {y0, y1}, {z0, _}} = box(stock)

    [
      {:edge, :left, x0 - px0},
      {:edge, :right, px1 - x1},
      {:edge, :front, y0 - py0},
      {:edge, :back, py1 - y1},
      {:through, z0 - pz0}
    ]
    |> Enum.filter(fn issue -> elem(issue, tuple_size(issue) - 1) > @tolerance end)
  end

  defp broadcast(db, stock), do: Phoenix.PubSub.broadcast(@pubsub, topic(db), {:stock, stock})
  defp topic(db), do: "stock:#{inspect(db)}"
end
