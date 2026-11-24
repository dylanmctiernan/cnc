defmodule CNC.Controllers.Config do
  @moduledoc """
  A connected controller's configuration, which lives on the controller.

  FluidNC keeps config files (YAML) on its local filesystem and loads one at
  boot, named by `$Config/Filename`. Several can sit side by side (a
  baseline, a variation you're trying), and switching is choosing another
  file and restarting. What's running can differ from the file once settings
  are changed live; `save_running_as/2` writes it out.

  Settings can be changed live (`change/5`: FluidNC's `$/path=value`, read
  back to confirm it took). What's not saved yet comes from the controller:
  the running config (`$CD`) against the file it loaded, so changes made any
  way (the console too) show. A file leaves defaults out, so for a setting
  it doesn't mention the app's own record of what it was (kept per
  controller in the app's database) fills in. `save/3` writes the running
  config over the loaded file, keeping the file's previous text in the
  controller's history first. A restart drops unsaved changes (the
  controller reloads its file).

  Everything goes through `CNC.Machine.request/3`, so it needs the machine
  connected and `:idle` or `:alarm`.
  """

  alias CNC.Machine

  @type file :: %{name: String.t(), size: non_neg_integer}
  @type change :: %{path: String.t(), from: String.t(), to: String.t()}
  @type snapshot :: %{at: DateTime.t(), file: String.t(), text: String.t(), why: String.t()}

  @history_max 30

  @doc "The config files on the controller and the one it loads at boot."
  @spec files(GenServer.server()) ::
          {:ok, %{files: [file], active: String.t() | nil}} | {:error, term}
  def files(machine) do
    with {:ok, listing} <- Machine.request(machine, "$LocalFS/List"),
         {:ok, chosen} <- Machine.request(machine, "$Config/Filename") do
      files = listing |> parse_files() |> Enum.sort_by(&String.downcase(&1.name))
      {:ok, %{files: files, active: parse_filename(chosen)}}
    end
  end

  @doc "A config file's text."
  @spec show(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term}
  def show(machine, name) do
    with {:ok, name} <- valid_name(name),
         {:ok, lines} <- Machine.request(machine, "$LocalFS/Show=" <> name) do
      {:ok, text(lines)}
    else
      {:error, 66} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "The configuration the controller is running now (`$CD`)."
  @spec running(GenServer.server()) :: {:ok, String.t()} | {:error, term}
  def running(machine) do
    with {:ok, lines} <- Machine.request(machine, "$CD"), do: {:ok, text(lines)}
  end

  @doc """
  Write the running configuration to a file on the controller (`$CD=`):
  how to copy a config, or keep changes made live.
  """
  @spec save_running_as(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term}
  def save_running_as(machine, name) do
    with {:ok, name} <- valid_name(name),
         {:ok, _} <- Machine.request(machine, "$CD=" <> name),
         do: {:ok, name}
  end

  @doc """
  Load a different config file: chosen for boot, then the controller
  restarts (it comes back locked, like any reconnect). Only a file that's on
  the controller: FluidNC doesn't check, and would boot with nothing.
  """
  @spec activate(GenServer.server(), String.t()) :: :ok | {:error, term}
  def activate(machine, name) do
    with {:ok, name} <- valid_name(name),
         {:ok, %{files: files}} <- files(machine),
         true <- Enum.any?(files, &(&1.name == name)) || {:error, :not_found},
         {:ok, _} <- Machine.request(machine, "$Config/Filename=" <> name),
         {:ok, _} <- Machine.request(machine, "$Bye") do
      :ok
    else
      # The restart can cut the link before its ok arrives
      {:error, :reset} -> :ok
      other -> other
    end
  end

  @doc """
  Delete a config file (not the one loaded at boot). With a database and
  controller id, its text goes into the history first.
  """
  @spec delete(GenServer.server(), String.t(), {GenServer.server(), String.t()} | nil) ::
          :ok | {:error, term}
  def delete(machine, name, keep \\ nil) do
    with {:ok, name} <- valid_name(name),
         {:ok, %{active: active}} <- files(machine),
         false <- name == active && {:error, :active},
         :ok <- keep_in_history(machine, keep, name, "before deleting"),
         {:ok, _} <- Machine.request(machine, "$LocalFS/Delete=" <> name),
         do: :ok
  end

  ## Settings

  @doc ~S"""
  The settings in a config's text, in order: `[{path, value}]`, with paths
  as FluidNC takes them (`axes/x/max_rate_mm_per_min`, lower case).

      iex> CNC.Controllers.Config.parse(~s|name: "R"\naxes:\n  X:\n    steps_per_mm: 80\n    motor0:\n      pulloff_mm: 2\n|)
      [{"name", "R"}, {"axes/x/steps_per_mm", "80"}, {"axes/x/motor0/pulloff_mm", "2"}]
  """
  @spec parse(String.t()) :: [{String.t(), String.t()}]
  def parse(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({[], []}, fn line, {stack, acc} ->
      case Regex.run(~r/^(\s*)([^:#\s][^:]*):\s?(.*)$/, line) do
        [_, indent, key, value] ->
          depth = String.length(indent)
          stack = Enum.drop_while(stack, fn {d, _} -> d >= depth end)
          key = key |> String.trim() |> String.downcase()

          case unquote_value(String.trim(value)) do
            "" ->
              {[{depth, key} | stack], acc}

            value ->
              path = Enum.join(Enum.reverse(for({_, k} <- stack, do: k), [key]), "/")
              {stack, [{path, value} | acc]}
          end

        nil ->
          {stack, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # YAML quoting: FluidNC's dump writes strings bare.
  defp unquote_value(<<q, rest::binary>> = value) when q in [?", ?'] do
    if String.ends_with?(rest, <<q>>) and rest != "",
      do: String.slice(rest, 0..-2//1),
      else: value
  end

  defp unquote_value(value), do: value

  @doc "One setting's value on the controller now."
  @spec get(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term}
  def get(machine, path) do
    with :ok <- valid_path(path),
         {:ok, lines} <- request_setting(machine, "$/" <> path) do
      prefix = String.downcase("$/" <> path <> "=")

      Enum.find_value(lines, {:error, :no_value}, fn line ->
        if String.starts_with?(String.downcase(line), prefix),
          do: {:ok, binary_part(line, byte_size(prefix), byte_size(line) - byte_size(prefix))}
      end)
    end
  end

  @doc """
  Set one setting live and read it back. FluidNC answers `ok` even when it
  didn't apply a value (a bad number, a setting that only changes in the
  file), so the read-back decides: `{:error, {:not_applied, why}}`.
  """
  @spec set(GenServer.server(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term}
  def set(machine, path, value) do
    with :ok <- valid_path(path),
         {:ok, value} <- valid_value(value),
         {:ok, said} <- request_setting(machine, "$/#{path}=#{value}"),
         {:ok, now} <- get(machine, path) do
      if same?(now, value), do: {:ok, now}, else: {:error, {:not_applied, why(said)}}
    end
  end

  @doc """
  Change a setting live and remember it as not saved yet. Changing it back
  to where it was forgets it.
  """
  @spec change(GenServer.server(), GenServer.server(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term}
  def change(machine, db, id, path, value) do
    with :ok <- valid_path(path),
         {:ok, before} <- get(machine, path),
         {:ok, now} <- set(machine, path, value) do
      path = String.downcase(path)
      list = CubDB.get(db, {:config_changes, id}, [])
      from = Enum.find_value(list, before, &(&1.path == path && &1.from))
      list = Enum.reject(list, &(&1.path == path))
      list = if same?(now, from), do: list, else: list ++ [%{path: path, from: from, to: now}]
      :ok = CubDB.put(db, {:config_changes, id}, list)
      {:ok, now}
    end
  end

  @doc """
  What's not saved yet: settings where the controller is running something
  other than the file it loaded (in the file's order), then settings the
  file doesn't mention that were changed through the app. One back at its
  old value (undone, or the controller restarted) is gone.
  """
  @spec changes(GenServer.server(), GenServer.server(), String.t()) ::
          {:ok, [change]} | {:error, term}
  def changes(machine, db, id) do
    with {:ok, %{active: file}} when is_binary(file) <- files(machine),
         {:ok, file_text} <- show(machine, file),
         {:ok, running_text} <- running(machine) do
      in_file = parse(file_text)
      in_file_paths = MapSet.new(in_file, &elem(&1, 0))
      running = Map.new(parse(running_text))

      from_board =
        for {path, was} <- in_file,
            now = running[path],
            now != nil and not same?(now, was),
            do: %{path: path, from: was, to: now}

      recorded = recorded(db, id)

      from_app =
        for c <- recorded,
            not MapSet.member?(in_file_paths, c.path),
            now = running[c.path],
            now != nil and not same?(now, c.from),
            do: %{c | to: now}

      if from_app != recorded, do: CubDB.put(db, {:config_changes, id}, from_app)
      {:ok, from_board ++ from_app}
    else
      {:ok, %{active: nil}} -> {:error, :no_active_file}
      other -> other
    end
  end

  @doc "Put a changed setting back to what it was (in the file, or before the app changed it)."
  @spec undo(GenServer.server(), GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, term}
  def undo(machine, db, id, path) do
    with {:ok, list} <- changes(machine, db, id),
         %{from: from} <- Enum.find(list, &(&1.path == path)) || {:error, :not_found},
         {:ok, _} <- set(machine, path, from) do
      CubDB.put(db, {:config_changes, id}, Enum.reject(recorded(db, id), &(&1.path == path)))
    end
  end

  defp recorded(db, id), do: CubDB.get(db, {:config_changes, id}, [])

  @doc """
  Save what's running over the file the controller loads (`$CD=<file>`),
  keeping the file's previous text in the history. FluidNC writes every
  setting, defaults included, so the file gets longer.
  """
  @spec save(GenServer.server(), GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:error, term}
  def save(machine, db, id) do
    with {:ok, %{active: file}} when is_binary(file) <- files(machine),
         :ok <- keep_in_history(machine, {db, id}, file, "before saving changes"),
         {:ok, _} <- Machine.request(machine, "$CD=" <> file) do
      :ok = CubDB.put(db, {:config_changes, id}, [])
      {:ok, file}
    else
      {:ok, %{active: nil}} -> {:error, :no_active_file}
      other -> other
    end
  end

  @doc "Earlier versions of this controller's config files, newest first."
  @spec history(GenServer.server(), String.t()) :: [snapshot]
  def history(db, id), do: CubDB.get(db, {:config_history, id}, [])

  @doc "Forget a controller's changes and history (it was removed)."
  def forget(db, id), do: CubDB.delete_multi(db, [{:config_changes, id}, {:config_history, id}])

  defp keep_in_history(_machine, nil, _file, _why), do: :ok

  defp keep_in_history(machine, {db, id}, file, why) do
    with {:ok, text} <- show(machine, file) do
      entry = %{at: DateTime.utc_now(:second), file: file, text: text, why: why}

      :ok =
        CubDB.put(db, {:config_history, id}, Enum.take([entry | history(db, id)], @history_max))
    end
  end

  # A setting's reply, as lines; an unknown path is error:3.
  defp request_setting(machine, line) do
    case Machine.request(machine, line) do
      {:error, 3} -> {:error, :unknown_setting}
      other -> other
    end
  end

  defp why(lines) do
    Enum.find_value(lines, "the controller kept the old value", fn
      "[MSG:ERR: " <> rest -> String.trim_trailing(rest, "]")
      "$" <> _ -> nil
      "[" <> _ -> nil
      line -> if String.trim(line) != "", do: line
    end)
  end

  # Numbers compare as numbers (FluidNC prints 900 as 900.000).
  defp same?(a, b) do
    case {Float.parse(a), Float.parse(b)} do
      {{x, ""}, {y, ""}} -> abs(x - y) < 1.0e-6
      _ -> String.downcase(String.trim(a)) == String.downcase(String.trim(b))
    end
  end

  defp valid_path(path) when is_binary(path) do
    if Regex.match?(~r/\A[A-Za-z0-9_]+(\/[A-Za-z0-9_]+)*\z/, path),
      do: :ok,
      else: {:error, :invalid_setting}
  end

  defp valid_path(_), do: {:error, :invalid_setting}

  defp valid_value(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= 64 and String.printable?(value) and
         not String.contains?(value, ["\n", "\r", "="]),
       do: {:ok, value},
       else: {:error, :invalid_value}
  end

  defp valid_value(_), do: {:error, :invalid_value}

  @doc """
  A config file name: letters, digits, `-`, `_`, `.`, ending in `.yaml`
  (added when there's no extension).

      iex> CNC.Controllers.Config.valid_name("fast accel")
      {:error, :invalid_name}
      iex> CNC.Controllers.Config.valid_name("fast-accel")
      {:ok, "fast-accel.yaml"}
  """
  @spec valid_name(String.t()) :: {:ok, String.t()} | {:error, :invalid_name}
  def valid_name(name) when is_binary(name) do
    name = String.trim(name)
    name = if Regex.match?(~r/\.ya?ml\z/i, name), do: name, else: name <> ".yaml"

    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,40}\.ya?ml\z/i, name),
      do: {:ok, name},
      else: {:error, :invalid_name}
  end

  def valid_name(_), do: {:error, :invalid_name}

  # "[FILE: config.yaml|SIZE:2212]" (other files and directories are skipped)
  defp parse_files(lines) do
    for line <- lines,
        [_, name, size] <- [Regex.run(~r/^\[FILE:\s*(.+?)\|SIZE:(\d+)\]$/, line)],
        Regex.match?(~r/\.ya?ml\z/i, name),
        do: %{name: name, size: String.to_integer(size)}
  end

  defp parse_filename(lines) do
    Enum.find_value(lines, fn
      "$Config/Filename=" <> name -> String.trim(name)
      _ -> nil
    end)
  end

  defp text(lines), do: Enum.join(lines, "\n") <> "\n"
end
