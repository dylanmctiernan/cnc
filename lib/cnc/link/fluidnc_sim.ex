defmodule CNC.Link.FluidNCSim do
  @moduledoc """
  Link to FluidNC running natively on this computer (see `mix cnc.fluidnc.build`):
  the real firmware as a child program, spoken to over its stdin/stdout.

  Each connect starts FluidNC on its run directory's config.yaml (the
  controller's own, kept across restarts); FluidNC reads it at start, and
  its `$` settings (NVS) live in the same folder.

  Options:

    * `:executable` — the FluidNC binary (default `.fluidnc/bin/fluidnc`)
    * `:config` — the starting config.yaml (text), written only if the run
      directory has none yet: after that the sim's own file is the source of
      truth and persists, like a board's flash
    * `:run_dir` — FluidNC's own folder (config, settings); one per
      controller (`CNC.Controllers` gives each FluidNC sim profile its own)

  Stock FluidNC, set up from outside rather than patched:

    * Its telnet and HTTP servers would listen on every network interface
      with no authentication, bypassing the app's PIN. They're switched off
      in its settings store before it starts, so it never opens them.
    * It runs under a small `sh` watchdog: closing the link stops it, and if
      this app dies without closing, the watchdog notices within a second
      and stops it too (FluidNC itself ignores its input closing).
  """
  @behaviour CNC.Link
  use GenServer
  require Logger

  @impl CNC.Link
  def start_link(owner, opts), do: GenServer.start_link(__MODULE__, {owner, opts})

  @impl CNC.Link
  def write_line(pid, line), do: GenServer.cast(pid, {:write, [line, ?\n]})

  @impl CNC.Link
  def write_realtime(pid, byte), do: GenServer.cast(pid, {:write, <<byte>>})

  @impl CNC.Link
  def close(pid), do: GenServer.cast(pid, :close)

  # Real firmware, but nothing physical moves.
  @impl CNC.Link
  def simulated?, do: true

  @doc "Default path of the native FluidNC binary."
  def default_executable, do: Path.expand(".fluidnc/bin/fluidnc")

  @doc "True if the native FluidNC binary has been built."
  def available?(opts \\ []),
    do: File.exists?(Keyword.get(opts, :executable, default_executable()))

  # Runs FluidNC ($1) on our stdin/stdout. Stops it when we're told to
  # (TERM from close/1) or when the app is gone (our parent, erl_child_setup,
  # exits with the BEAM). Exits with FluidNC's status if it ends by itself.
  @watchdog """
  "$1" <&0 &
  child=$!
  trap 'kill "$child" 2>/dev/null' EXIT HUP INT TERM
  parent=$PPID
  while kill -0 "$child" 2>/dev/null; do
    kill -0 "$parent" 2>/dev/null || exit 0
    sleep 1
  done
  trap - EXIT
  wait "$child"
  """

  @doc """
  Set up a directory for FluidNC to run in: `config` as its config.yaml if it
  has none yet, and its telnet/HTTP servers switched off. FluidNC's settings store
  (native_nvs/) holds one file per setting; these two say "off" (a single 0
  byte). Done before every start.
  """
  def prepare_run_dir(run_dir, config) do
    nvs = Path.join(run_dir, "native_nvs")
    config_file = Path.join([run_dir, "native_localfs", "config.yaml"])

    with :ok <- File.mkdir_p(Path.dirname(config_file)),
         :ok <- first_config(config_file, config),
         :ok <- File.mkdir_p(nvs),
         :ok <- File.write(Path.join(nvs, "Telnet.Enable"), <<0>>) do
      File.write(Path.join(nvs, "HTTP.Enable"), <<0>>)
    end
  end

  # The config is the controller's own once it exists (edits and $CD saves
  # persist, like a board's flash): only a missing one is written.
  defp first_config(file, config) do
    cond do
      File.exists?(file) -> :ok
      is_binary(config) -> File.write(file, config)
      true -> {:error, :no_config}
    end
  end

  @impl GenServer
  def init({owner, opts}) do
    Process.flag(:trap_exit, true)
    {:ok, %{owner: owner, opts: opts, port: nil, os_pid: nil, buffer: ""}, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, %{opts: opts} = s) do
    exe = Keyword.get(opts, :executable, default_executable())
    config = Keyword.get(opts, :config)
    run_dir = Keyword.get(opts, :run_dir, Path.expand(".fluidnc/run"))

    with true <- File.exists?(exe) || {:error, {:not_built, exe}},
         :ok <- prepare_run_dir(run_dir, config) do
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          cd: run_dir,
          args: ["-c", @watchdog, "fluidnc", exe]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      send(s.owner, {:link, :connected})
      {:noreply, %{s | port: port, os_pid: os_pid}}
    else
      {:error, reason} ->
        Logger.warning("FluidNC start failed: #{inspect(reason)} (run mix cnc.fluidnc.build)")
        {:stop, {:shutdown, {:connect_failed, reason}}, s}
    end
  end

  @impl GenServer
  def handle_cast(:close, s), do: {:stop, {:shutdown, :closed}, stop_program(s)}

  def handle_cast({:write, data}, s) do
    Port.command(s.port, data)
    {:noreply, s}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = s) do
    {lines, rest} = split_lines(s.buffer <> data)
    for line <- lines, do: send(s.owner, {:link, :line, line})
    {:noreply, %{s | buffer: rest}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = s) do
    Logger.warning("FluidNC exited (status #{status})")
    send(s.owner, {:link, :disconnected})
    {:stop, {:shutdown, {:exited, status}}, %{s | port: nil, os_pid: nil}}
  end

  def handle_info({:EXIT, _, _}, s), do: {:noreply, s}

  @impl GenServer
  def terminate(_reason, s), do: stop_program(s)

  defp stop_program(%{port: nil} = s), do: s

  defp stop_program(%{port: port, os_pid: os_pid} = s) do
    if Port.info(port), do: Port.close(port)
    # TERM the watchdog, which stops FluidNC.
    if os_pid, do: System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    %{s | port: nil, os_pid: nil}
  end

  # Complete lines (without \r\n) and the unterminated remainder.
  defp split_lines(data) do
    parts = String.split(data, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.map(complete, &String.trim_trailing(&1, "\r")), rest}
  end
end
