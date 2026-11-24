defmodule CNC.Grbl.ResponseTest do
  use ExUnit.Case, async: true

  alias CNC.Grbl.{Response, Status}

  # Lines in the shapes Grbl 1.1 / grblHAL / FluidNC emit. Replace or extend
  # with lines captured from the grblHAL sim (M5) and the real board (Phase 2).
  @cases [
    {"ok", :ok},
    {"ok\r\n", :ok},
    {"error:15", {:error, 15}},
    {"error:20 (Unsupported command)", {:error, 20}},
    {"ALARM:1", {:alarm, 1}},
    {"ALARM:11\r", {:alarm, 11}},
    {"[MSG:'$H'|'$X' to unlock]", {:msg, "'$H'|'$X' to unlock"}},
    {"[MSG:Caution: Unlocked]", {:msg, "Caution: Unlocked"}},
    {"Grbl 1.1h ['$' for help]", {:banner, "Grbl 1.1h ['$' for help]"}},
    {"GrblHAL 1.1f ['$' or '$HELP' for help]",
     {:banner, "GrblHAL 1.1f ['$' or '$HELP' for help]"}},
    {"Grbl 3.7.8 [FluidNC v3.7.8 (wifi) '$' for help]",
     {:banner, "Grbl 3.7.8 [FluidNC v3.7.8 (wifi) '$' for help]"}},
    # Not (yet) interpreted
    {"[GC:G0 G54 G17 G21 G90 G94 M5 M9 T0 F0 S0]",
     {:info, "GC", "G0 G54 G17 G21 G90 G94 M5 M9 T0 F0 S0"}},
    {"[VER:1.1f.20261123:]", {:info, "VER", "1.1f.20261123:"}},
    {"[DRIVER:Simulator]", {:info, "DRIVER", "Simulator"}},
    {"[G54:0.000,0.000,0.000]", {:info, "G54", "0.000,0.000,0.000"}},
    {"[no colon]", {:unknown, "[no colon]"}},
    {"$130=1250.000", {:setting, 130, "1250.000"}},
    {"$10=511", {:setting, 10, "511"}},
    {"$N0=", {:unknown, "$N0="}},
    {"$=5", {:unknown, "$=5"}},
    {"", {:unknown, ""}},
    # Malformed known forms
    {"error:", {:unknown, "error:"}},
    {"error:abc", {:unknown, "error:abc"}},
    {"ALARM:-1", {:unknown, "ALARM:-1"}},
    {"[MSG:no close", {:unknown, "[MSG:no close"}},
    {"<Idle|MPos:0.000,0.000,0.000", {:unknown, "<Idle|MPos:0.000,0.000,0.000"}},
    {"<>", {:unknown, "<>"}},
    {"<Idle|MPos:1,2>", {:unknown, "<Idle|MPos:1,2>"}},
    {"<Idle|MPos:a,b,c>", {:unknown, "<Idle|MPos:a,b,c>"}},
    {"<Hold:x|MPos:0,0,0>", {:unknown, "<Hold:x|MPos:0,0,0>"}}
  ]

  for {line, expected} <- @cases do
    test "parse #{inspect(line)}" do
      assert Response.parse(unquote(line)) == unquote(Macro.escape(expected))
    end
  end

  @statuses [
    {"<Idle|MPos:0.000,0.000,0.000|FS:0,0|WCO:0.000,0.000,0.000>",
     %Status{
       state: :idle,
       mpos: {0.0, 0.0, 0.0},
       wpos: {0.0, 0.0, 0.0},
       wco: {0.0, 0.0, 0.0},
       feed: 0.0,
       spindle: 0.0
     }},
    {"<Jog|MPos:12.500,-3.250,0.000|Bf:15,127|FS:1200,0>",
     %Status{
       state: :jog,
       mpos: {12.5, -3.25, 0.0},
       buffer: {15, 127},
       feed: 1200.0,
       spindle: 0.0
     }},
    {"<Hold:1|MPos:10.000,20.000,-1.000|FS:0.0,0|Ov:100,100,100>",
     %Status{
       state: :hold,
       substate: 1,
       mpos: {10.0, 20.0, -1.0},
       feed: 0.0,
       spindle: 0.0,
       overrides: {100, 100, 100}
     }},
    # WPos reporting ($10=0) with WCO -> derive MPos
    {"<Run|WPos:1.000,2.000,3.000|FS:500,12000|WCO:100.000,200.000,-50.000>",
     %Status{
       state: :run,
       wpos: {1.0, 2.0, 3.0},
       mpos: {101.0, 202.0, -47.0},
       wco: {100.0, 200.0, -50.0},
       feed: 500.0,
       spindle: 12000.0
     }},
    # grblHAL alarm with pins and extra fields we don't model
    {"<Alarm|MPos:0.000,0.000,0.000|Bf:35,1023|FS:0,0|Pn:XYZ|A:S|H:0,7>",
     %Status{
       state: :alarm,
       mpos: {0.0, 0.0, 0.0},
       buffer: {35, 1023},
       feed: 0.0,
       spindle: 0.0
     }},
    {"<Door:2|MPos:1.000,1.000,1.000|F:300>",
     %Status{state: :door, substate: 2, mpos: {1.0, 1.0, 1.0}, feed: 300.0}},
    # 4-axis report: extra axes dropped
    {"<Home|MPos:5.000,6.000,7.000,90.000|FS:0,0>",
     %Status{state: :home, mpos: {5.0, 6.0, 7.0}, feed: 0.0, spindle: 0.0}},
    # Unknown state names are kept as :unknown
    {"<Wibble|MPos:0,0,0>", %Status{state: :unknown, mpos: {0.0, 0.0, 0.0}}}
  ]

  for {line, expected} <- @statuses do
    test "status #{inspect(line)}" do
      assert Response.parse(unquote(line)) == {:status, unquote(Macro.escape(expected))}
    end
  end
end
