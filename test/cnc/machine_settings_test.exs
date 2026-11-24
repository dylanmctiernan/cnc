defmodule CNC.Machine.SettingsTest do
  use CNC.MachineCase, async: true

  describe "settings" do
    setup do
      m =
        start_machine(
          {CNC.ScriptedLink, test: self()},
          "settings-#{System.unique_integer()}"
        )

      assert_receive {:scripted_link, _fake, ^m}
      %{m: m}
    end

    test "read on connect", %{m: m} do
      connect(m, "Alarm", {0, 0}, ["$110=3000.000", "$130=1250.000"])
      assert Machine.settings(m) == %{110 => "3000.000", 130 => "1250.000"}
    end
  end
end
