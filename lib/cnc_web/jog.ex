defmodule CNCWeb.Jog do
  @moduledoc """
  Jogging from a screen, shared by the machine screen and the pendant: the
  speed tiers, and checking what the joystick sends (`CNCWeb`'s `Joystick`
  hook: an analog X/Y/Z vector and a tier) before it reaches the machine.
  """

  # name: {X/Y mm/s, Z mm/s} at full deflection
  @tiers [fine: {5, 1}, normal: {20, 5}, fast: {50, 10}]

  def tiers, do: @tiers

  @doc "A tier by name, as sent by a screen."
  def tier(name) do
    case Enum.find(Keyword.keys(@tiers), &(to_string(&1) == name)) do
      nil -> :error
      tier -> {:ok, tier}
    end
  end

  @doc "An analog vector, each part in -1..1, as sent by a screen."
  def analog_vector(x, y, z) do
    with {:ok, x} <- analog(x), {:ok, y} <- analog(y), {:ok, z} <- analog(z), do: {:ok, {x, y, z}}
  end

  defp analog(v) when is_number(v) and v >= -1 and v <= 1, do: {:ok, v}

  defp analog(v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> analog(f)
      _ -> :error
    end
  end

  defp analog(_), do: :error
end
