defmodule CNC.Machine do
  @moduledoc """
  Machine state and jogging: the public API for everything above the domain.

  A single `gen_statem` (`CNC.Machine.Server`) owns the transport and caches
  what the controller reports. The controller remains the source of truth;
  after any (re)connect or reset the machine is locked in `:alarm` until
  `unlock/1` or `home/1`.

  Snapshots are broadcast on `CNC.PubSub`, topic `"machine"`, as
  `{:machine, %CNC.Machine.State{}}` (at most every 50 ms).

  Every function takes an optional server (pid or name), defaulting to the
  application's instance. Commands invalid for the current state return
  `{:error, {:invalid_state, state}}`.
  """
  use Boundary, deps: [CNC.Grbl, CNC.Transport], exports: [State]

  alias CNC.Machine.{Jog, Server, State}

  @type server :: :gen_statem.server_ref()
  @type reply :: :ok | {:error, {:invalid_state, atom}}

  defdelegate child_spec(opts), to: Server
  defdelegate start_link(opts), to: Server

  @doc "Subscribe the caller to `{:machine, %State{}}` broadcasts."
  def subscribe(topic \\ "machine"), do: Phoenix.PubSub.subscribe(CNC.PubSub, topic)

  @spec status(server) :: State.t()
  def status(server \\ __MODULE__), do: call(server, :status)

  @spec unlock(server) :: reply
  def unlock(server \\ __MODULE__), do: call(server, :unlock)

  @spec home(server) :: reply
  def home(server \\ __MODULE__), do: call(server, :home)

  def feed_hold(server \\ __MODULE__), do: call(server, :feed_hold)
  def resume(server \\ __MODULE__), do: call(server, :resume)
  def reset(server \\ __MODULE__), do: call(server, :reset)

  @doc """
  Start or update a continuous jog. `vector` is `{dx, dy}` with each in
  `-1..1` (held arrow keys); `{0, 0}` stops. Must be kept alive with
  `jog_heartbeat/1` at least every 250 ms, or the jog is cancelled.
  """
  @spec jog(server, Jog.vector(), Jog.tier()) :: reply
  def jog(server \\ __MODULE__, {dx, dy} = vector, tier)
      when dx in -1..1 and dy in -1..1 and tier in [:fine, :normal, :fast],
      do: call(server, {:jog, vector, tier})

  @spec jog_heartbeat(server) :: reply
  def jog_heartbeat(server \\ __MODULE__), do: call(server, :jog_heartbeat)

  @doc "Stop jogging now (sends jog cancel). Never refused."
  @spec jog_stop(server) :: :ok
  def jog_stop(server \\ __MODULE__), do: call(server, :jog_stop)

  @doc "A single relative move of `mm` along each non-zero axis of `vector`."
  @spec jog_step(server, Jog.vector(), number) :: reply | {:error, :at_limit}
  def jog_step(server \\ __MODULE__, {dx, dy} = vector, mm)
      when dx in -1..1 and dy in -1..1 and vector != {0, 0} and mm > 0 and mm <= 50,
      do: call(server, {:jog_step, vector, mm})

  defp call(server, request), do: :gen_statem.call(server, request)
end
