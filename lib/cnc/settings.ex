defmodule CNC.Settings do
  @moduledoc """
  Controller settings, for people: what each `$N` means, its unit and type,
  how to group them, validation of edited values, and the diff between what
  the controller has and what's been edited.

  Pure: reading and writing go through `CNC.Machine` (`settings/1`,
  `write_settings/2`), the only process that talks to the controller.

  The catalogue covers the standard Grbl 1.1 / grblHAL core settings.
  Anything else a controller reports is still listed, under "Other", with
  its raw number.
  """
  use Boundary, deps: [], exports: []

  @type number_id :: non_neg_integer
  @type kind :: :float | :int | :bool | :mask
  @type spec :: %{
          n: number_id,
          name: String.t(),
          unit: String.t() | nil,
          kind: kind,
          group: String.t(),
          help: String.t(),
          min: number | nil
        }

  @groups ["Motion", "Homing", "Limits", "Spindle", "Signals", "Stepper", "Planner", "Reporting"]

  @catalogue [
    {100, "X steps per mm", "steps/mm", :float, "Motion",
     "Motor steps for 1 mm of X travel. Wrong values mean wrong distances.", 0},
    {101, "Y steps per mm", "steps/mm", :float, "Motion", "Motor steps for 1 mm of Y travel.", 0},
    {102, "Z steps per mm", "steps/mm", :float, "Motion", "Motor steps for 1 mm of Z travel.", 0},
    {110, "X max speed", "mm/min", :float, "Motion",
     "Fastest X may move, including jogs and rapids.", 0},
    {111, "Y max speed", "mm/min", :float, "Motion", "Fastest Y may move.", 0},
    {112, "Z max speed", "mm/min", :float, "Motion", "Fastest Z may move.", 0},
    {120, "X acceleration", "mm/s²", :float, "Motion", "How hard X speeds up and slows down.", 0},
    {121, "Y acceleration", "mm/s²", :float, "Motion", "How hard Y speeds up and slows down.", 0},
    {122, "Z acceleration", "mm/s²", :float, "Motion", "How hard Z speeds up and slows down.", 0},
    {130, "X max travel", "mm", :float, "Motion",
     "Length of X travel. Used for soft limits, homing, and this app's bed size.", 0},
    {131, "Y max travel", "mm", :float, "Motion", "Length of Y travel.", 0},
    {132, "Z max travel", "mm", :float, "Motion", "Length of Z travel.", 0},
    {22, "Homing", nil, :mask, "Homing",
     "Homing cycle on/off (grblHAL: bit 0 on, other bits are options).", nil},
    {23, "Homing direction invert", "axis mask", :mask, "Homing",
     "Which axes home toward negative (bit 0 X, 1 Y, 2 Z).", nil},
    {24, "Homing locate speed", "mm/min", :float, "Homing",
     "Slow approach to find the switch precisely.", 0},
    {25, "Homing seek speed", "mm/min", :float, "Homing", "Fast search for the switch.", 0},
    {26, "Homing debounce", "ms", :int, "Homing", "Wait for switch bounce to settle.", nil},
    {27, "Homing pull-off", "mm", :float, "Homing",
     "How far to back off the switch after homing.", nil},
    {20, "Soft limits", nil, :bool, "Limits", "Refuse moves outside travel. Needs homing.", nil},
    {21, "Hard limits", nil, :bool, "Limits", "Stop immediately when a limit switch triggers.",
     nil},
    {5, "Limit pins invert", "mask", :mask, "Limits",
     "Invert limit switch inputs (normally-closed switches).", nil},
    {30, "Spindle max", "rpm", :float, "Spindle", "Spindle speed at full output.", nil},
    {31, "Spindle min", "rpm", :float, "Spindle", "Lowest spindle speed.", nil},
    {32, "Laser mode", nil, :bool, "Spindle",
     "Laser mode: power follows motion, no spindle stops.", nil},
    {2, "Step pulse invert", "axis mask", :mask, "Signals", "Invert step signals per axis.", nil},
    {3, "Direction invert", "axis mask", :mask, "Signals",
     "Reverse an axis's direction (bit 0 X, 1 Y, 2 Z).", nil},
    {4, "Step enable invert", nil, :bool, "Signals", "Invert the stepper enable output.", nil},
    {6, "Probe pin invert", nil, :bool, "Signals", "Invert the probe input.", nil},
    {0, "Step pulse", "µs", :float, "Stepper", "Length of each step pulse.", 0},
    {1, "Step idle delay", "ms", :int, "Stepper",
     "Keep motors powered this long after motion (255 = always).", nil},
    {11, "Junction deviation", "mm", :float, "Planner",
     "Cornering speed: higher is faster through corners.", nil},
    {12, "Arc tolerance", "mm", :float, "Planner", "How closely arcs are approximated.", 0},
    {10, "Status report options", "mask", :mask, "Reporting",
     "What status reports include (MPos/WPos, buffers).", nil},
    {13, "Report in inches", nil, :bool, "Reporting",
     "Report positions in inches. This app expects mm.", nil}
  ]

  @specs Map.new(@catalogue, fn {n, name, unit, kind, group, help, min} ->
           {n, %{n: n, name: name, unit: unit, kind: kind, group: group, help: help, min: min}}
         end)

  @doc "What we know about setting `n`, or a raw entry if it isn't catalogued."
  @spec spec(number_id) :: spec
  def spec(n),
    do:
      Map.get(@specs, n, %{
        n: n,
        name: "$#{n}",
        unit: nil,
        kind: :raw,
        group: "Other",
        help: "",
        min: nil
      })

  @doc """
  Group the controller's settings (`%{n => value}`) for display:
  `[{group, [%{spec | value: value}]}]`, known groups first, then "Other".
  """
  def grouped(settings) do
    settings
    |> Enum.map(fn {n, value} -> Map.put(spec(n), :value, value) end)
    |> Enum.group_by(& &1.group)
    |> Enum.sort_by(fn {group, _} -> Enum.find_index(@groups ++ ["Other"], &(&1 == group)) end)
    |> Enum.map(fn {group, items} -> {group, Enum.sort_by(items, & &1.n)} end)
  end

  @doc """
  Check an edited value for setting `n`. Returns the value as the
  controller should receive it, or a reason for the person.
  """
  @spec validate(number_id, String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate(n, value) when is_binary(value), do: value |> String.trim() |> check(spec(n))

  defp check("", _), do: {:error, "Enter a value."}

  defp check(v, %{kind: :bool}) when v in ["0", "1"], do: {:ok, v}
  defp check(_, %{kind: :bool}), do: {:error, "Use 1 for on or 0 for off."}

  defp check(v, %{kind: kind}) when kind in [:int, :mask] do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> {:ok, Integer.to_string(n)}
      _ -> {:error, "Use a whole number, 0 or more."}
    end
  end

  defp check(v, %{kind: :float, min: min}) do
    case Float.parse(v) do
      {f, ""} when is_number(min) and f <= min -> {:error, "Must be more than #{min}."}
      {_, ""} -> {:ok, v}
      _ -> {:error, "Use a number, e.g. 1250 or 0.5."}
    end
  end

  # Uncatalogued: pass through anything printable on one line.
  defp check(v, %{kind: :raw}) do
    if String.printable?(v) and not String.contains?(v, ["\n", "\r", "$", "="]),
      do: {:ok, v},
      else: {:error, "That value can't be sent."}
  end

  @doc """
  The settings that would actually change: `[{n, from, to}]` for edits whose
  value differs from the controller's (numerically, so `1250` vs
  `1250.000` isn't a change).
  """
  def diff(current, edits) do
    for {n, to} <- Enum.sort(edits),
        from = Map.get(current, n),
        from != nil,
        not same?(from, to) do
      {n, from, to}
    end
  end

  defp same?(a, b) do
    case {Float.parse(a), Float.parse(b)} do
      {{x, ""}, {y, ""}} -> x == y
      _ -> a == b
    end
  end
end
