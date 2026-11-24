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
  the controller printed them). Re-read after every connect and after
  `write_settings/2`; `State.settings_rev` changes when they do.
  """
  @spec settings(server) :: %{non_neg_integer => String.t()}
  def settings(server \\ __MODULE__), do: call(server, :settings)

  @doc """
  Write settings to the controller: `[{n, value}]`, values already checked
  with `CNC.Settings.validate/2`. Only when `:idle` or `:alarm` and not
  moving. Results arrive in `State.settings_write`; when all are answered
  the settings are read back.
  """
  @spec write_settings(server, [{non_neg_integer, String.t()}]) ::
          reply | {:error, :moving | :invalid_value}
  def write_settings(server \\ __MODULE__, changes) when is_list(changes) do
    if Enum.all?(changes, fn {n, v} ->
         is_integer(n) and n >= 0 and v =~ ~r/\A[0-9A-Za-z.\-]+\z/
       end),
       do: call(server, {:write_settings, changes}),
       else: {:error, :invalid_value}
  end

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
  Only when `:idle`. Values must be numbers within ±100 000 mm.
  """
  @spec set_work_position(server, [{:x | :y | :z, number}]) :: reply | {:error, :invalid_value}
  def set_work_position(server \\ __MODULE__, values) when is_list(values) and values != [] do
    if Enum.all?(values, fn {axis, v} ->
         axis in [:x, :y, :z] and is_number(v) and abs(v) <= 100_000
       end),
       do: call(server, {:work_position, values}),
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

  defp call(server, request), do: :gen_statem.call(server, request)
end
