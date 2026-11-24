defmodule CNCWeb.Instance do
  @moduledoc """
  Which machine, program store and controllers a screen drives: the app's
  own (`CNC.Machine`, `CNC.Program`, `CNC.Controllers`) unless the session
  names others.

  Only tests name others (`config :cnc, instance_from_session: true` in
  test.exs): each test starts its own machine and program store, so screen
  tests run in parallel without sharing one machine. In dev and prod the
  session is ignored, so a browser can never point a screen elsewhere.
  """

  defstruct machine: CNC.Machine,
            topic: "machine",
            program: CNC.Program,
            program_topic: "program",
            controllers: CNC.Controllers,
            controllers_topic: "controllers"

  @type t :: %__MODULE__{
          machine: GenServer.server(),
          topic: String.t(),
          program: GenServer.server(),
          program_topic: String.t(),
          controllers: GenServer.server(),
          controllers_topic: String.t()
        }

  @from_session? Application.compile_env(:cnc, :instance_from_session, false)

  @doc "The instance for a LiveView session."
  @spec from_session(map) :: t
  if @from_session? do
    def from_session(%{"cnc_instance" => %__MODULE__{} = instance}), do: instance
  end

  def from_session(_session), do: %__MODULE__{}
end
