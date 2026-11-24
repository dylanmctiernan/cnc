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

    test "read on connect; written one by one, with results, then read back", %{m: m} do
      connect(m, "Alarm", {0, 0}, ["$110=3000.000", "$130=1250.000"])
      assert Machine.settings(m) == %{110 => "3000.000", 130 => "1250.000"}
      rev = Machine.status(m).settings_rev

      :ok = Machine.write_settings(m, [{110, "2500"}, {130, "1000"}])
      assert_receive {:line, "$110=2500"}
      assert_receive {:line, "$130=1000"}
      assert Machine.status(m).settings_write == %{110 => :pending, 130 => :pending}

      ok(m)
      send(m, {:link, :line, "error:3"})
      assert Machine.status(m).settings_write == %{110 => :ok, 130 => {:error, 3}}

      # All answered: read back.
      assert_receive {:line, "$$"}
      for l <- ["$110=2500.000", "$130=1250.000", "ok"], do: send(m, {:link, :line, l})
      assert Machine.settings(m) == %{110 => "2500.000", 130 => "1250.000"}
      assert Machine.status(m).settings_rev > rev
    end

    test "refused while jogging or moving, and for bad values", %{m: m} do
      idle(m)
      :ok = Machine.jog(m, {1, 0}, :normal)
      assert Machine.write_settings(m, [{110, "1"}]) == {:error, {:invalid_state, :jogging}}
      :ok = Machine.jog_stop(m)
      send(m, {:link, :line, "<Jog|MPos:1,0,0|FS:100,0>"})
      assert Machine.write_settings(m, [{110, "1"}]) == {:error, :moving}
      assert Machine.write_settings(m, [{110, "1\n$H"}]) == {:error, :invalid_value}
    end
  end
end
