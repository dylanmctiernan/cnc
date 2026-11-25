defmodule CNCWeb.TouchOff do
  @moduledoc """
  Setting X0 / Y0 by touching the stock's edges with the bit, as a
  machinist does with fine steps (Inc): bring the bit to the edge from
  outside, then say which edge it's on. Shared by the machine screen and
  the pendant; pure, the caller sets the offset.

  The bit's radius is allowed for (`CNCApp.Bit.radius/1`; 0 with no bit
  set, the edge then at the tool's centre): touching the left edge from
  its left, the edge is at the tool's X plus the radius.

  Where the zero goes depends on the stock (`CNCApp.Stock`):

    * zero at the front-left corner: the left (front) edge is X0 (Y0); the
      right (back) edge is one width (depth) past it
    * zero at the centre: half a width from the edge; once both opposite
      edges have been touched, their midpoint (the radius cancels, and the
      stock's real size no longer matters), and the measured size is
      reported against the stock's
    * no stock set: only the left and front edges (the zero at the corner)

  Edges touched are remembered (`touched`, machine coordinates) so the
  second of a pair can use the first.
  """

  @sides [:left, :right, :front, :back]

  @type side :: :left | :right | :front | :back
  @type touched :: %{optional(side) => float}

  def sides, do: @sides

  @doc "The axis an edge sets."
  def axis(side) when side in [:left, :right], do: :x
  def axis(side) when side in [:front, :back], do: :y

  @doc "The edges for an axis (nil for Z: no edges to touch)."
  def sides_for(:x), do: [:left, :right]
  def sides_for(:y), do: [:front, :back]
  def sides_for(:z), do: []

  @doc "Whether this edge can set the zero: the far edges need the stock's size."
  def usable?(side, stock), do: stock != nil or side in [:left, :front]

  @doc """
  The bit is touching `side` of the stock: where the zero goes.
  `{:ok, %{axis:, zero:, measured:, touched:}}`: `zero` is the work offset
  for the axis (machine coordinates), `measured` the size between this
  edge and the opposite one when both have been touched (else nil), and
  `touched` the edges remembered now. `{:error, :no_position}` before the
  controller has reported one; `{:error, :needs_stock}` for a far edge
  with no stock set.
  """
  def touch(side, mpos, stock, bit, touched \\ %{}) when side in @sides do
    cond do
      mpos == nil ->
        {:error, :no_position}

      not usable?(side, stock) ->
        {:error, :needs_stock}

      true ->
        r = CNCApp.Bit.radius(bit)
        {mx, my, _} = mpos

        edge =
          case side do
            :left -> mx + r
            :right -> mx - r
            :front -> my + r
            :back -> my - r
          end

        other = Map.get(touched, opposite(side))
        measured = other && abs(edge - other)
        touched = Map.put(touched, side, edge)

        {:ok,
         %{
           axis: axis(side),
           zero: zero(side, edge, other, stock),
           measured: measured,
           touched: touched
         }}
    end
  end

  # Corner zero (or no stock): the low edge is the zero
  defp zero(side, edge, _other, nil) when side in [:left, :front], do: edge
  defp zero(side, edge, _other, %{zero: :front_left}) when side in [:left, :front], do: edge
  # (the far edge with the near one already touched: the near one, measured)
  defp zero(side, _edge, other, %{zero: :front_left})
       when side in [:right, :back] and other != nil,
       do: other

  defp zero(:right, edge, _other, %{zero: :front_left, width: w}), do: edge - w
  defp zero(:back, edge, _other, %{zero: :front_left, depth: d}), do: edge - d
  # Centre zero: the midpoint once both edges are known, else half a size in
  defp zero(_side, edge, other, %{zero: :center}) when other != nil, do: (edge + other) / 2
  defp zero(:left, edge, nil, %{zero: :center, width: w}), do: edge + w / 2
  defp zero(:right, edge, nil, %{zero: :center, width: w}), do: edge - w / 2
  defp zero(:front, edge, nil, %{zero: :center, depth: d}), do: edge + d / 2
  defp zero(:back, edge, nil, %{zero: :center, depth: d}), do: edge - d / 2

  @doc """
  What a touch did, in words, for the message line: where the zero went,
  the radius allowed for, and the measured size when both edges are known.
  """
  def describe(side, %{axis: axis, measured: measured}, stock, bit) do
    name = axis |> to_string() |> String.upcase()
    size = if axis == :x, do: "width", else: "depth"

    where =
      case {stock, side, measured} do
        {%{zero: :center}, _, m} when m != nil ->
          "#{name}0 midway between the edges"

        {%{zero: :center}, s, nil} ->
          "#{name}0 half the stock's #{size} in from the #{s} edge"

        {%{zero: :front_left}, s, m} when s in [:right, :back] and m != nil ->
          "#{name}0 kept on the #{opposite(s)} edge"

        {%{zero: :front_left}, s, nil} when s in [:right, :back] ->
          "#{name}0 the stock's #{size} from the #{s} edge"

        {_, s, _} ->
          "#{name}0 on the #{s} edge"
      end

    radius =
      case bit do
        nil -> "no bit set, so taken at the tool's centre"
        bit -> "the bit's #{CNCWeb.Run.size(CNCApp.Bit.radius(bit))} mm radius allowed for"
      end

    measured =
      case {measured, stock} do
        {nil, _} ->
          ""

        {m, nil} ->
          " Measured #{CNCWeb.Run.size(m)} mm across."

        {m, st} ->
          " Measured #{CNCWeb.Run.size(m)} mm across (the stock says #{CNCWeb.Run.size(if axis == :x, do: st.width, else: st.depth)})."
      end

    "#{where} (#{radius}).#{measured}"
  end

  defp opposite(:left), do: :right
  defp opposite(:right), do: :left
  defp opposite(:front), do: :back
  defp opposite(:back), do: :front
end
