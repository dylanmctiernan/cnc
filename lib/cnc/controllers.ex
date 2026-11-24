defmodule CNC.Controllers do
  @moduledoc """
  The controllers you have and which one the machine is using. A controller
  profile (`CNC.Controllers.Profile`) is a board plus a link; its
  configuration lives on the controller itself.

  Profiles and the active choice are kept in the app's CubDB (`CNC.DB`,
  `<data_dir>/db`): crash-safe, synced on every write. A `controllers.json`
  from before is imported once and renamed `controllers.json.migrated`.
  The list starts empty: you add (import) your controllers, and can fork a
  sim to experiment. With none active the machine stays disconnected.
  Selecting a profile tells `CNC.Machine` to connect to it (the controller
  starts locked, as on any connect).

  A link set in config (`config :cnc, :link`, e.g. from `CNC_LINK=…`)
  overrides the active profile: the machine uses it directly and selecting
  is refused, so scripts and tests stay explicit.

  Each FluidNC sim profile runs in its own folder under the data dir, so its
  config and settings persist across restarts, like a board's flash.
  """
  use Boundary, deps: [CNC.Machine, CNC.Link, CNC.Boards], exports: [Profile]
  use GenServer
  require Logger

  alias CNC.Boards, as: Board
  alias CNC.Controllers.Profile
  alias CNC.Machine

  @topic "controllers"

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "All profiles, in the order added."
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "The active profile, or nil (none yet, or a link override is in use)."
  def active(server \\ __MODULE__), do: GenServer.call(server, :active)

  @doc "True when a configured link overrides the profiles (CNC_LINK, tests)."
  def overridden?(server \\ __MODULE__), do: GenServer.call(server, :overridden?)

  @doc """
  Make a profile active and connect the machine to it. Refused while the
  machine is moving (switching drops the link).
  """
  @spec select(GenServer.server(), String.t()) ::
          :ok | {:error, :not_found | :overridden | :moving}
  def select(server \\ __MODULE__, id), do: GenServer.call(server, {:select, id}, 10_000)

  @doc """
  Change how a controller is reached (only links its board can use). The
  controller and its config stay the same; if it's the active one, the
  machine reconnects over the new link.
  """
  @spec update_link(GenServer.server(), String.t(), map) :: {:ok, Profile.t()} | {:error, term}
  def update_link(server \\ __MODULE__, id, link),
    do: GenServer.call(server, {:update_link, id, link}, 10_000)

  @doc """
  Fork a FluidNC sim (or the fake sim): a new, independent copy to
  experiment with. A FluidNC sim's folder (config and settings) is copied.
  Boards can't be forked: a board holds one config, so two profiles would
  share it (use config versions for experiments).
  """
  @spec fork(GenServer.server(), String.t()) :: {:ok, Profile.t()} | {:error, term}
  def fork(server \\ __MODULE__, id), do: GenServer.call(server, {:fork, id})

  @doc "Remove a profile (not the active one)."
  @spec remove(GenServer.server(), String.t()) :: :ok | {:error, :active | :not_found}
  def remove(server \\ __MODULE__, id), do: GenServer.call(server, {:remove, id})

  @doc "Serial ports on this computer: `[{device, description}]`, for choosing a USB link."
  def serial_ports do
    for {name, info} <- Enum.sort(CNC.Link.UART.ports()) do
      device = if String.starts_with?(name, "/dev/"), do: name, else: "/dev/" <> name

      description =
        [info[:manufacturer], info[:description]] |> Enum.reject(&is_nil/1) |> Enum.join(", ")

      {device, description}
    end
  end

  @doc """
  Add a profile: `%{name: ..., board: ..., link: ...}`. The link defaults to
  the board's usual kind (a serial link needs its `port`).
  """
  @spec add(GenServer.server(), map) :: {:ok, Profile.t()} | {:error, term}
  def add(server \\ __MODULE__, attrs), do: GenServer.call(server, {:add, attrs})

  @doc "Receive `{:controllers, %{profiles: [...], active: id | nil}}` on changes."
  def subscribe(topic \\ @topic), do: Phoenix.PubSub.subscribe(CNC.PubSub, topic)

  @doc """
  The `CNC.Link` adapter and options for a profile. A FluidNC sim gets its
  own run folder under `data_dir`, starting from its board's default config.
  """
  @spec link_spec(Profile.t(), Path.t()) :: {module, keyword}
  def link_spec(%Profile{link: %{type: :fluidnc_sim}} = p, data_dir) do
    {CNC.Link.FluidNCSim,
     run_dir: Path.join([data_dir, "controllers", p.id, "fluidnc"]), config: Board.config(p.board)}
  end

  def link_spec(%Profile{link: %{type: :fake_sim}}, _), do: {CNC.Link.FakeSim, []}

  def link_spec(%Profile{link: %{type: :serial, port: port, speed: speed}}, _),
    do: {CNC.Link.UART, port: port, speed: speed}

  def link_spec(%Profile{link: %{type: :tcp, host: host, port: port}}, _),
    do: {CNC.Link.TCP, host: host, port: port}

  ## Server

  @impl true
  def init(opts) do
    data_dir =
      Keyword.get_lazy(opts, :data_dir, fn -> Application.fetch_env!(:cnc, :data_dir) end)

    s = %{
      data_dir: data_dir,
      db: Keyword.get(opts, :db, CNC.DB),
      machine: Keyword.get(opts, :machine, Machine),
      overridden?:
        Keyword.get_lazy(opts, :overridden?, fn -> Application.get_env(:cnc, :link) != nil end),
      profiles: [],
      active: nil,
      # Tests seed just the fake sim (no FluidNC process, no dev data)
      seed: Keyword.get(opts, :seed, :none),
      topic: Keyword.get(opts, :topic, @topic)
    }

    s = load(s)
    if not s.overridden?, do: connect_active(s)
    {:ok, s}
  end

  @impl true
  def handle_call(:list, _from, s), do: {:reply, s.profiles, s}
  def handle_call(:active, _from, %{overridden?: true} = s), do: {:reply, nil, s}
  def handle_call(:active, _from, s), do: {:reply, find(s, s.active), s}
  def handle_call(:overridden?, _from, s), do: {:reply, s.overridden?, s}

  def handle_call({:select, _id}, _from, %{overridden?: true} = s),
    do: {:reply, {:error, :overridden}, s}

  def handle_call({:select, id}, _from, s) do
    cond do
      find(s, id) == nil ->
        {:reply, {:error, :not_found}, s}

      moving?(s) ->
        {:reply, {:error, :moving}, s}

      true ->
        s = save(%{s | active: id})
        connect_active(s)
        {:reply, :ok, s}
    end
  end

  def handle_call({:update_link, id, link}, _from, s) do
    active? = id == s.active and not s.overridden?

    with %Profile{} = profile <- find(s, id) || {:error, :not_found},
         false <- (active? and moving?(s)) && {:error, :moving},
         {:ok, link} <- link_for(profile.board, link) do
      profile = %{profile | link: link}
      s = save(%{s | profiles: Enum.map(s.profiles, &if(&1.id == id, do: profile, else: &1))})
      if active?, do: connect_active(s)
      {:reply, {:ok, profile}, s}
    else
      {:error, _} = error -> {:reply, error, s}
    end
  end

  def handle_call({:fork, id}, _from, s) do
    case find(s, id) do
      nil ->
        {:reply, {:error, :not_found}, s}

      %Profile{link: %{type: type}} = profile when type in [:fluidnc_sim, :fake_sim] ->
        copy = %{profile | id: Profile.new_id(), name: profile.name <> " (copy)"}

        if type == :fluidnc_sim do
          from = Path.join([s.data_dir, "controllers", id])
          to = Path.join([s.data_dir, "controllers", copy.id])
          if File.dir?(from), do: File.cp_r!(from, to)
        end

        {:reply, {:ok, copy}, save(%{s | profiles: s.profiles ++ [copy]})}

      _board ->
        {:reply, {:error, :not_forkable}, s}
    end
  end

  # A FluidNC sim's folder is its flash: nothing else can use it, so it goes
  # with the profile. A board keeps its config (it's on the board).
  def handle_call({:remove, id}, _from, s) do
    profile = find(s, id)

    cond do
      profile == nil ->
        {:reply, {:error, :not_found}, s}

      id == s.active ->
        {:reply, {:error, :active}, s}

      true ->
        if profile.link.type == :fluidnc_sim,
          do: File.rm_rf(Path.join([s.data_dir, "controllers", id]))

        {:reply, :ok, save(%{s | profiles: Enum.reject(s.profiles, &(&1.id == id))})}
    end
  end

  def handle_call({:add, attrs}, _from, s) do
    case build(attrs) do
      {:ok, profile} ->
        s = save(%{s | profiles: s.profiles ++ [profile]})
        {:reply, {:ok, profile}, s}

      error ->
        {:reply, error, s}
    end
  end

  defp build(%{name: name, board: board} = attrs) when is_binary(name) and name != "" do
    with true <- board in Board.ids() || {:error, :unknown_board},
         {:ok, link} <- link_for(board, Map.get(attrs, :link)) do
      {:ok, %Profile{id: Profile.new_id(), name: name, board: board, link: link}}
    end
  end

  defp build(_), do: {:error, :invalid}

  # Only a link the board can use (CNC.Boards.links/1), with its defaults.
  defp link_for(board, nil), do: link_for(board, %{type: Board.default_link(board)})

  defp link_for(board, %{type: type} = link) do
    cond do
      type not in Board.links(board) -> {:error, {:link_not_supported, type}}
      type == :serial and not is_map_key(link, :port) -> {:error, :serial_port_required}
      type == :serial -> {:ok, Map.put_new(link, :speed, 115_200)}
      type == :tcp and not is_map_key(link, :host) -> {:error, :tcp_host_required}
      type == :tcp -> {:ok, Map.put_new(link, :port, 23)}
      true -> {:ok, link}
    end
  end

  defp link_for(_board, _), do: {:error, :invalid_link}

  defp find(s, id), do: Enum.find(s.profiles, &(&1.id == id))

  defp moving?(s) do
    status = Machine.status(s.machine)
    status.moving? or status.state in [:jogging, :homing]
  end

  defp connect_active(s) do
    case find(s, s.active) do
      nil -> :ok
      profile -> Machine.connect(s.machine, link_spec(profile, s.data_dir))
    end
  end

  ## Storage

  @key :controllers

  defp load(s) do
    case CubDB.get(s.db, @key) do
      %{profiles: maps, active: active} ->
        %{s | profiles: for(m <- maps, {:ok, p} <- [Profile.from_map(m)], do: p), active: active}

      nil ->
        import_json(s) || seed(s)
    end
  end

  # controllers.json from before CubDB: import it once, keep it renamed.
  defp import_json(s) do
    file = Path.join(s.data_dir, "controllers.json")

    with {:ok, json} <- File.read(file),
         {:ok, %{"profiles" => raw} = data} <- Jason.decode(json) do
      profiles = for map <- raw, {:ok, p} <- [Profile.from_json(map)], do: p
      s = save(%{s | profiles: profiles, active: data["active"]})
      File.rename(file, file <> ".migrated")
      Logger.info("imported #{length(profiles)} controllers from controllers.json")
      s
    else
      _ -> nil
    end
  end

  # First run starts empty: you add (import) your controllers. Tests seed
  # just the fake sim.
  defp seed(%{seed: :fake_only} = s) do
    fake = %Profile{
      id: Profile.new_id(),
      name: "Fake sim",
      board: :fake_sim,
      link: %{type: :fake_sim}
    }

    save(%{s | profiles: [fake], active: fake.id})
  end

  defp seed(s), do: save(%{s | profiles: [], active: nil})

  defp save(s) do
    :ok =
      CubDB.put(s.db, @key, %{profiles: Enum.map(s.profiles, &Profile.to_map/1), active: s.active})

    Phoenix.PubSub.broadcast(
      CNC.PubSub,
      s.topic,
      {:controllers, %{profiles: s.profiles, active: s.active}}
    )

    s
  end
end
