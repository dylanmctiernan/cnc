defmodule CNCWeb.ConsoleHelp do
  @moduledoc """
  Reference for the controller console: common Grbl / grblHAL / FluidNC
  commands. Each entry is `{command, description}` or
  `{command, description, firmware}` when it's firmware-specific.

  Examples are filled into the input, never sent directly.
  """

  @sections [
    %{
      title: "Look at the controller",
      note: nil,
      items: [
        {"$", "List the commands this controller understands"},
        {"$$", "Show all settings"},
        {"$G", "Show active G-code modes: units, absolute or relative, work coordinates"},
        {"$#", "Show stored offsets: work coordinates G54–G59, G92, tool length, last probe"},
        {"$I", "Show firmware version and build options"},
        {"$N", "Show the lines run at power-up"},
        {"?", "Request one status report (the same as the status polls)"}
      ]
    },
    %{
      title: "Machine actions",
      note: "Same as the buttons. Hold, resume and reset act immediately.",
      items: [
        {"$X", "Unlock after an alarm without homing"},
        {"$H", "Run the homing cycle"},
        {"!", "Hold: decelerate and pause"},
        {"~", "Resume after a hold"},
        {"$C", "Toggle check mode: G-code is checked but nothing moves"}
      ]
    },
    %{
      title: "Moves and coordinates",
      note:
        "Typed moves skip the jog safety stop and the host's travel limit. " <>
          "Positions are in the active work coordinates unless G53 is used.",
      items: [
        {"G21", "Use millimetres"},
        {"G90", "Positions are absolute"},
        {"G91", "Positions are relative to where the tool is"},
        {"G0 X100 Y50", "Rapid move to X100 Y50"},
        {"G1 X10 Y10 F600", "Move to X10 Y10 at 600 mm/min"},
        {"G53 G0 X0 Y0", "Rapid move in machine coordinates (this line only)"},
        {"$J=G91 G21 X10 F1200", "Jog 10 mm in +X at 1200 mm/min (cancel with Esc)"},
        {"G10 L20 P1 X0 Y0", "Make the current position the work zero (G54)"},
        {"G54", "Use work coordinates 1"}
      ]
    },
    %{
      title: "Change settings",
      note: "Stored on the controller and kept across restarts. Check with $$ first.",
      items: [
        {"$130=1250", "X travel in mm ($131 Y, $132 Z). The bed view follows."},
        {"$110=3000", "X max speed in mm/min ($111 Y, $112 Z)"},
        {"$120=500", "X acceleration in mm/s² ($121 Y, $122 Z)"},
        {"$100=80", "X steps per mm ($101 Y, $102 Z). Wrong values mean wrong distances."}
      ]
    },
    %{
      title: "Firmware-specific",
      note: "FluidNC shorthands may differ between versions: try $CMD to check.",
      items: [
        {"$HELP", "List help topics", "grblHAL"},
        {"$CD", "Show the active config.yaml ($Config/Dump)", "FluidNC"},
        {"$S", "List settings ($Settings/List)", "FluidNC"},
        {"$CMD", "List commands ($Commands/List)", "FluidNC"}
      ]
    }
  ]

  def sections do
    for section <- @sections do
      %{section | items: Enum.map(section.items, &item/1)}
    end
  end

  defp item({cmd, desc}), do: %{cmd: cmd, desc: desc, firmware: nil}
  defp item({cmd, desc, firmware}), do: %{cmd: cmd, desc: desc, firmware: firmware}
end
