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
  Parse and load a file, replacing any loaded one. Parsing runs in the
  caller. Options: `:server` (default `CNC.Program`); the rest go to
  `CNC.GCode.parse/2` (e.g. `:rapid_rate`).
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
  def subscribe(pubsub \\ CNC.PubSub), do: Phoenix.PubSub.subscribe(pubsub, @topic)

  @impl true
  def init(opts), do: {:ok, %{program: nil, pubsub: Keyword.get(opts, :pubsub, CNC.PubSub)}}

  @impl true
  def handle_call(:current, _from, s), do: {:reply, s.program, s}

  def handle_call({:put, program}, _from, s) do
    Phoenix.PubSub.broadcast(s.pubsub, @topic, {:program, program})
    {:reply, :ok, %{s | program: program}}
  end
end
