defmodule CNCWeb.TouchOffTest do
  use ExUnit.Case, async: true

  alias CNCWeb.TouchOff

  @bit %{diameter: 6.0, kind: :flat, angle: nil}
  @corner %{width: 100.0, depth: 50.0, thickness: 12.0, zero: :front_left}
  @centre %{@corner | zero: :center}

  test "the left edge, touched from its left: the edge is the bit's radius past the tool" do
    assert {:ok, %{axis: :x, zero: 203.0, measured: nil}} =
             TouchOff.touch(:left, {200.0, 0.0, 0.0}, @corner, @bit)

    # No bit set: at the tool's centre; no stock: the near edges still work
    assert {:ok, %{zero: 200.0}} = TouchOff.touch(:left, {200.0, 0.0, 0.0}, nil, nil)
    assert {:ok, %{axis: :y, zero: 103.0}} = TouchOff.touch(:front, {0.0, 100.0, 0.0}, nil, @bit)
  end

  test "corner zero from the far edge: one width back; with the near edge touched, that edge" do
    # The right edge at 303 - 3 = 300: X0 a width (100) to its left
    assert {:ok, %{zero: 200.0}} = TouchOff.touch(:right, {303.0, 0.0, 0.0}, @corner, @bit)

    {:ok, %{touched: touched}} = TouchOff.touch(:left, {197.0, 0.0, 0.0}, @corner, @bit)
    # The left edge at 200; the right at 299.5: X0 stays on the left edge, 99.5 measured
    assert {:ok, %{zero: 200.0, measured: 99.5}} =
             TouchOff.touch(:right, {302.5, 0.0, 0.0}, @corner, @bit, touched)
  end

  test "centre zero: half a size in from one edge; midway once both are touched" do
    assert {:ok, %{zero: 250.0}} = TouchOff.touch(:left, {197.0, 0.0, 0.0}, @centre, @bit)
    {:ok, %{touched: touched}} = TouchOff.touch(:left, {197.0, 0.0, 0.0}, @centre, @bit)

    # The right edge at 299 (the stock is really 99 wide): midway, 249.5
    assert {:ok, %{zero: 249.5, measured: 99.0} = t} =
             TouchOff.touch(:right, {302.0, 0.0, 0.0}, @centre, @bit, touched)

    assert TouchOff.describe(:right, t, @centre, @bit) ==
             "X0 midway between the edges (the bit's 3 mm radius allowed for). " <>
               "Measured 99 mm across (the stock says 100)."
  end

  test "the far edges need the stock's size; nothing without a position" do
    assert TouchOff.touch(:right, {0.0, 0.0, 0.0}, nil, @bit) == {:error, :needs_stock}
    refute TouchOff.usable?(:back, nil)
    assert TouchOff.touch(:left, nil, @corner, @bit) == {:error, :no_position}
  end
end
