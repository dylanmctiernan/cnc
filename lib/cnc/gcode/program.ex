defmodule CNC.GCode.Program do
  @moduledoc """
  A parsed G-code file (see `CNC.GCode.parse/2`). All lengths in mm, in the
  program's work coordinates.

    * `path` — the toolpath, packed for storage and drawing: per segment, 8
      little-endian float32s `[kind, x0, y0, z0, x1, y1, z1, line]`, kind 0
      for rapids and 1 for feeds, in order; arcs are already chords. 32 bytes
      a segment, readable as a `Float32Array` in the browser.
      `CNC.GCode.segments/1` unpacks it.
    * `segment_count` — segments in `path`
    * `bounds` / `cut_bounds` — `{{x_min, x_max}, {y_min, y_max},
      {z_min, z_max}}` over all moves / feed (cutting) moves only; `nil` if
      none
    * `cut_mm`, `rapid_mm` — path lengths
    * `seconds` — run time at 100% feed and rapids, as the controller's
      planner would move it: feeds, max rates, acceleration, corners,
      dwells (`CNC.GCode.Timing`)
    * `timeline` — the same, line by line, cumulative and split into
      feed, rapid and fixed time (`CNC.GCode.Timing.at/2`), so progress
      can be measured in time and overrides applied
    * `tools` — tool numbers in `M6` order; `max_spindle` — highest `S`
    * `warnings` — `[%{kind, line, count}]`: things the preview can't show
      faithfully, first occurrence first
  """

  @type point :: {float, float, float}
  @type bounds :: {{float, float}, {float, float}, {float, float}} | nil
  @type t :: %__MODULE__{
          path: binary,
          segment_count: non_neg_integer,
          lines: non_neg_integer,
          bounds: bounds,
          cut_bounds: bounds,
          cut_mm: float,
          rapid_mm: float,
          seconds: float,
          timeline: binary,
          tools: [integer | nil],
          max_spindle: float,
          warnings: [%{kind: term, line: non_neg_integer, count: pos_integer}]
        }

  defstruct path: <<>>,
            segment_count: 0,
            lines: 0,
            bounds: nil,
            cut_bounds: nil,
            cut_mm: 0.0,
            rapid_mm: 0.0,
            seconds: 0.0,
            timeline: <<>>,
            tools: [],
            max_spindle: 0.0,
            warnings: []
end
