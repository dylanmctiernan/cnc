defmodule CNC.Machine do
  @moduledoc """
  Machine state and jogging: the public API for everything above the domain.

  A single `gen_statem` (`CNC.Machine.Server`) owns the link and caches
  what the controller reports. The controller remains the source of truth;
  after any (re)connect or reset the machine is locked in `:alarm` until
  `unlock/1` or `home/1`.

  Snapshots are broadcast on `CNC.PubSub`, topic `"machine"`, as
  `{:machine, %CNC.Machine.State{}}` (at most every 50 ms).

  Every function takes an optional server (pid or name), defaulting to the
  application's instance. Commands invalid for the current state return
  `{:error, {:invalid_state, state}}`.
  """
  use Boundary, deps: [CNC.Grbl, CNC.Link], exports: [State, Protocol]

  alias CNC.Machine.{Jog, Server, State}

  @type server :: :gen_statem.server_ref()
  @type reply :: :ok | {:error, {:invalid_state, atom}}

  defdelegate child_spec(opts), to: Server
  defdelegate start_link(opts), to: Server

  @doc "Subscribe the caller to `{:machine, %State{}}` broadcasts."
  def subscribe(topic \\ "machine"), do: Phoenix.PubSub.subscribe(CNC.PubSub, topic)

  @doc """
  Subscribe to raw controller traffic as `{:machine_console, entry}` (see
  `CNC.Machine.Console`). Status polls are a separate, opt-in stream.
  """
  def subscribe_console(topic \\ "machine"),
    do: Phoenix.PubSub.subscribe(CNC.PubSub, topic <> ":console")

  def unsubscribe_console(topic \\ "machine"),
    do: Phoenix.PubSub.unsubscribe(CNC.PubSub, topic <> ":console")

  def subscribe_polls(topic \\ "machine"),
    do: Phoenix.PubSub.subscribe(CNC.PubSub, topic <> ":console:polls")

  def unsubscribe_polls(topic \\ "machine"),
    do: Phoenix.PubSub.unsubscribe(CNC.PubSub, topic <> ":console:polls")

  @doc "Recent traffic (last 200 entries, polls excluded), oldest first."
  @spec console(server) :: [CNC.Machine.Console.entry()]
  def console(server \\ __MODULE__), do: call(server, :console)

  @spec status(server) :: State.t()
  def status(server \\ __MODULE__), do: call(server, :status)

  @spec unlock(server) :: reply
  def unlock(server \\ __MODULE__), do: call(server, :unlock)

  @spec home(server) :: reply
  def home(server \\ __MODULE__), do: call(server, :home)

  @doc """
  Run a G-code file: stream it to the controller (state `:running`). Only
  from `:idle` with nothing in flight (`{:error, :busy}` otherwise). Hold
  and Resume pause it; `abort/1` stops it. Progress is in the status's
  `job`, the outcome in `last_job`.
  """
  @spec run(server, String.t(), binary) :: reply | {:error, term}
  def run(server \\ __MODULE__, name, text), do: call(server, {:run, name, text})

  @doc "Abort the running job: a soft reset (the machine comes back locked)."
  def abort(server \\ __MODULE__), do: call(server, :abort)

  @doc "Feed override: `:reset` (100%), `:plus10`, `:minus10`, `:plus1`, `:minus1`."
  def feed_override(server \\ __MODULE__, op), do: call(server, {:feed_override, op})

  def feed_hold(server \\ __MODULE__), do: call(server, :feed_hold)
  def resume(server \\ __MODULE__), do: call(server, :resume)
  def reset(server \\ __MODULE__), do: call(server, :reset)

  @doc """
  Start or update a continuous jog. `vector` is `{dx, dy, dz}` (or `{dx, dy}`
  for X/Y only), each component in `-1..1`: keys give -1/0/1, a joystick any
  value in between (speed is proportional). All zeros stops. Must be kept
  alive with `jog_heartbeat/1` at least every 250 ms, or the jog is
  cancelled.
  """
  @spec jog(server, Jog.vector() | {number, number}, Jog.tier()) :: reply
  def jog(server \\ __MODULE__, vector, tier)

  def jog(server, {dx, dy}, tier), do: jog(server, {dx, dy, 0}, tier)

  def jog(server, {dx, dy, dz}, tier)
      when is_number(dx) and is_number(dy) and is_number(dz) and
             dx >= -1 and dx <= 1 and dy >= -1 and dy <= 1 and dz >= -1 and dz <= 1 and
             tier in [:fine, :normal, :fast] do
    if dx == 0 and dy == 0 and dz == 0,
      do: jog_stop(server),
      else: call(server, {:jog, {dx, dy, dz}, tier})
  end

  @spec jog_heartbeat(server) :: reply
  def jog_heartbeat(server \\ __MODULE__), do: call(server, :jog_heartbeat)

  @doc "Stop jogging now (sends jog cancel). Never refused."
  @spec jog_stop(server) :: :ok
  def jog_stop(server \\ __MODULE__), do: call(server, :jog_stop)

  @doc "A single relative move of `mm` along each non-zero axis of `vector` (`{dx, dy, dz}` or `{dx, dy}`)."
  @spec jog_step(server, Jog.vector() | {-1..1, -1..1}, number) :: reply | {:error, :at_limit}
  def jog_step(server \\ __MODULE__, vector, mm)

  def jog_step(server, {dx, dy}, mm), do: jog_step(server, {dx, dy, 0}, mm)

  def jog_step(server, {dx, dy, dz} = vector, mm)
      when dx in -1..1 and dy in -1..1 and dz in -1..1 and vector != {0, 0, 0} and mm > 0 and
             mm <= 50,
      do: call(server, {:jog_step, vector, mm})

  @doc """
  The controller's settings from the last read: `%{n => value}` (values as
  the controller printed them). Re-read after every connect and after a
  setting typed in the console; `State.settings_rev` changes when they do.
  (Changing the configuration is `CNC.Configuration`.)
  """
  @spec settings(server) :: %{non_neg_integer => String.t()}
  def settings(server \\ __MODULE__), do: call(server, :settings)

  @doc """
  Make the current position the work zero (G54) on the given axes, e.g.
  `[:x, :y]` or `[:z]`. Only when `:idle`.
  """
  @spec set_work_zero(server, [:x | :y | :z]) :: reply
  def set_work_zero(server \\ __MODULE__, axes) when is_list(axes) and axes != [] do
    if Enum.all?(axes, &(&1 in [:x, :y, :z])),
      do: set_work_position(server, for(axis <- Enum.uniq(axes), do: {axis, 0.0})),
      else: raise(ArgumentError, "axes must be :x, :y and/or :z, got #{inspect(axes)}")
  end

  @doc """
  Set what the current position reads in work coordinates (G54), without
  moving: `[x: 10.0]` makes here X = 10, so the work zero is 10 mm in −X.
  Only when `:idle` and stopped. The work zero this implies must be inside
  the travel (`{:error, :outside_travel}` otherwise).
  """
  @spec set_work_position(server, [{:x | :y | :z, number}]) ::
          reply | {:error, :invalid_value | :outside_travel | :moving}
  def set_work_position(server \\ __MODULE__, values) when is_list(values) and values != [] do
    if Enum.all?(values, fn {axis, v} ->
         axis in [:x, :y, :z] and is_number(v) and abs(v) <= 100_000
       end),
       do: call(server, {:work_position, values}),
       else: {:error, :invalid_value}
  end

  @doc """
  Put the work zero (G54) at absolute machine coordinates, without moving:
  `[x: 300.0]` makes machine X 300 the work X0. Only when `:idle`; the zero
  must be inside the travel.
  """
  @spec set_work_offset(server, [{:x | :y | :z, number}]) ::
          reply | {:error, :invalid_value | :outside_travel}
  def set_work_offset(server \\ __MODULE__, values) when is_list(values) and values != [] do
    if Enum.all?(values, fn {axis, v} ->
         axis in [:x, :y, :z] and is_number(v) and abs(v) <= 100_000
       end),
       do: call(server, {:work_offset, values}),
       else: {:error, :invalid_value}
  end

  @doc """
  Move to the work origin in X/Y: first lift Z to near the top of travel
  (never lowers it), then a rapid X/Y move. Both are jogs, so Esc/`jog_stop/1`
  cancels them. Only when `:idle`, the work offset is known, and the machine
  has stopped (`{:error, :moving}` while a previous move may still be
  running: the moves are computed from the reported position).
  """
  @spec go_to_work_zero(server) :: reply | {:error, :no_work_offset | :outside_travel | :moving}
  def go_to_work_zero(server \\ __MODULE__), do: call(server, :go_to_work_zero)

  @doc """
  Connect to another controller: `{adapter, opts}` (a `CNC.Link` adapter),
  or `nil` for none. Stops the current link first (with a jog cancel if
  it's connected); the new controller starts locked, as on any connect.
  """
  @spec connect(server, {module, keyword} | nil) :: :ok
  def connect(server \\ __MODULE__, link), do: call(server, {:connect, link})

  @doc """
  Send one line typed by a person straight to the controller (a terminal).

  Allowed when `:idle`, `:alarm` or `:busy`. `$X`, `$H` and `$$` behave like
  `unlock/1`, `home/1` and the settings read; after a setting write (`$N=…`)
  the settings are re-read so travel follows. Typed motion (`G0 X500`) is
  **not** covered by the jog dead-man or the host's travel clamp; the
  controller's own limits and the hardware e-stop still apply.
  """
  @spec send_raw(server, String.t()) :: reply | {:error, :invalid_line}
  def send_raw(server \\ __MODULE__, line) when is_binary(line) do
    line = String.trim(line)

    if line == "" or String.contains?(line, ["\n", "\r"]) or not String.printable?(line),
      do: {:error, :invalid_line},
      else: call(server, {:raw, line})
  end

  @doc """
  Send one command and collect its reply: every line the controller prints
  before its `ok` (or `error:N`). For commands with multi-line answers, like
  FluidNC's `$CD` (the running config) or `$LocalFS/List`.

  Only when `:idle` or `:alarm` (`{:error, {:invalid_state, s}}` otherwise).
  A reset or lost link while waiting gives `{:error, :reset}`.
  """
  @spec request(server, String.t(), timeout) ::
          {:ok, [String.t()]} | {:error, non_neg_integer | :reset | term}
  def request(server \\ __MODULE__, line, timeout \\ 10_000) when is_binary(line),
    do: :gen_statem.call(server, {:request, line}, timeout)

  @doc """
  Put a file onto the controller's filesystem (a config, say). Over USB or
  Wi-Fi this is XModem: the state is `:uploading` meanwhile, with status
  polling paused. The sims write the file directly. Only when `:idle` or
  `:alarm` with nothing in flight (`{:error, :busy}`).
  """
  @spec upload(server, String.t(), binary, timeout) ::
          {:ok, non_neg_integer} | {:error, term}
  def upload(server \\ __MODULE__, name, data, timeout \\ 120_000)
      when is_binary(name) and is_binary(data) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.\-]{0,60}\z/, name),
      do: :gen_statem.call(server, {:upload, name, data}, timeout),
      else: {:error, :invalid_name}
  end

  defp call(server, request), do: :gen_statem.call(server, request)
end
