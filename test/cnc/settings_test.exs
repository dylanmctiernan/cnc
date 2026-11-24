defmodule CNC.SettingsTest do
  use ExUnit.Case, async: true

  alias CNC.Settings

  describe "validate/2" do
    test "floats: numbers, above the minimum" do
      assert Settings.validate(130, " 1250 ") == {:ok, "1250"}
      assert Settings.validate(120, "500.5") == {:ok, "500.5"}
      assert {:error, "Must be more than 0."} = Settings.validate(100, "0")
      assert {:error, _} = Settings.validate(110, "fast")
    end

    test "booleans and masks" do
      assert Settings.validate(20, "1") == {:ok, "1"}
      assert {:error, "Use 1 for on or 0 for off."} = Settings.validate(20, "yes")
      assert Settings.validate(23, "007") == {:ok, "7"}
      assert {:error, _} = Settings.validate(23, "-1")
    end

    test "uncatalogued settings pass through, but never anything that could inject a command" do
      assert Settings.validate(398, "100") == {:ok, "100"}
      assert {:error, _} = Settings.validate(398, "1\n$H")
      assert {:error, _} = Settings.validate(398, "1=2")
      assert {:error, "Enter a value."} = Settings.validate(398, "  ")
    end
  end

  test "diff/2 only lists real changes (numerically)" do
    current = %{130 => "1250.000", 131 => "1250.000", 20 => "0"}

    assert Settings.diff(current, %{130 => "1250", 131 => "1000", 20 => "1"}) ==
             [{20, "0", "1"}, {131, "1250.000", "1000"}]
  end

  test "grouped/1: known groups in order, then Other" do
    groups = Settings.grouped(%{130 => "1250", 22 => "1", 999 => "5", 100 => "80"})
    assert Enum.map(groups, &elem(&1, 0)) == ["Motion", "Homing", "Other"]
    [{"Motion", motion} | _] = groups
    assert Enum.map(motion, & &1.n) == [100, 130]
    assert %{name: "$999", value: "5"} = groups |> List.last() |> elem(1) |> hd()
  end
end
