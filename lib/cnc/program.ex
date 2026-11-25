defmodule CNC.Program do
  @moduledoc """
  The loaded G-code file: one for the whole app, like the machine, so every
  device sees the same program. Holds it parsed (`CNC.GCode.Program`) along
  with its name and the original text (for running it later).

  Loading and clearing broadcast `{:program, %CNC.Program{} | nil}` on the
  `"program"` topic. Nothing is kept across restarts yet: a library of files
  comes with jobs.
  """
  use Boundary, deps: [CNC.GCode], exports: []
  use GenServer

  alias CNC.GCode

  @topic "program"

  @type t :: %__MODULE__{
          name: String.t(),
          bytes: non_neg_integer,
          loaded_at: DateTime.t(),
          text: binary,
          gcode: GCode.Program.t()
        }
  defstruct [:name, :bytes, :loaded_at, :text, :gcode]

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The program's time, as the controller's planner would run it
  (`CNC.GCode.Timing`): `{feed, rapid, fixed}` seconds through file line
  `line` (`time_at/2`), or the whole file (`time_total/1`), and those as
  seconds at given feed and rapid overrides (`seconds/3`). nil when there's
  no timeline.
  """
  def time_at(%__MODULE__{gcode: %{timeline: t}}, line) when byte_size(t) > 0,
    do: CNC.GCode.Timing.at(t, line)

  def time_at(_program, _line), do: nil

  def time_total(%__MODULE__{gcode: %{timeline: t}}) when byte_size(t) > 0,
    do: CNC.GCode.Timing.total(t)

  def time_total(_program), do: nil

  @doc "The controller's planner blocks for file line `line` (an arc is many)."
  def time_blocks(%__MODULE__{gcode: %{timeline: t}}, line), do: CNC.GCode.Timing.blocks(t, line)

  @doc "Where `point` is on file line `line`: `{distance_mm, fraction_along}`, or nil."
  def locate(%__MODULE__{gcode: gcode}, line, point), do: CNC.GCode.locate(gcode, line, point)

  @doc """
  The lead-in: from `from` (where the tool was at Start) to where the
  program's timed moves begin, as the file's opening moves take it (Z, then
  X/Y, at rapid). `{{feed, rapid, fixed} seconds, the point}`, or nil.
  Options as `CNC.GCode.Timing.plan/2`.
  """
  def lead_in(%__MODULE__{gcode: gcode}, {fx, fy, fz}, opts) do
    case CNC.GCode.first_point(gcode) do
      nil ->
        nil

      {tx, ty, tz} = to ->
        dz = tz - fz
        dxy = :math.sqrt((tx - fx) * (tx - fx) + (ty - fy) * (ty - fy))

        moves =
          [
            dz != 0 && {1, :rapid, abs(dz), {0.0, 0.0, dz / abs(dz)}, nil, 1},
            dxy > 0 && {2, :rapid, dxy, {(tx - fx) / dxy, (ty - fy) / dxy, 0.0}, nil, 1}
          ]
          |> Enum.filter(& &1)

        {moves |> CNC.GCode.Timing.plan(opts) |> CNC.GCode.Timing.total(), to}
    end
  end

  def lead_in(_program, _from, _opts), do: nil

  defdelegate seconds(times, feed_ov \\ 100, rapid_ov \\ 100), to: CNC.GCode.Timing

  @doc """
  Parse and load a file, replacing any loaded one. Parsing runs in the
  caller. Options: `:server` (default `CNC.Program`); the rest go to
  `CNC.GCode.parse/2` (`:max_rate`, `:accel`, `:junction`: what the time
  estimate plans with).
  """
  @spec load(String.t(), binary, keyword) :: {:ok, t} | {:error, :not_text}
  def load(name, text, opts \\ []) do
    {server, opts} = Keyword.pop(opts, :server, __MODULE__)

    if String.valid?(text) do
      program = %__MODULE__{
        name: name,
        bytes: byte_size(text),
        loaded_at: DateTime.utc_now(),
        text: text,
        gcode: GCode.parse(text, opts)
      }

      :ok = GenServer.call(server, {:put, program})
      {:ok, program}
    else
      {:error, :not_text}
    end
  end

  @doc "The loaded program, or nil."
  @spec current(GenServer.server()) :: t | nil
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @doc "Unload the program."
  def clear(server \\ __MODULE__), do: GenServer.call(server, {:put, nil})

  @doc "Receive `{:program, t | nil}` when the loaded program changes."
  def subscribe(topic \\ @topic), do: Phoenix.PubSub.subscribe(CNC.PubSub, topic)

  @impl true
  def init(opts) do
    {:ok,
     %{
       program: nil,
       pubsub: Keyword.get(opts, :pubsub, CNC.PubSub),
       topic: Keyword.get(opts, :topic, @topic)
     }}
  end

  @impl true
  def handle_call(:current, _from, s), do: {:reply, s.program, s}

  def handle_call({:put, program}, _from, s) do
    Phoenix.PubSub.broadcast(s.pubsub, s.topic, {:program, program})
    {:reply, :ok, %{s | program: program}}
  end
end
