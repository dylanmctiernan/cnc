defmodule CNC.Controllers.Config do
  @moduledoc """
  The controller's side of configuration: what's on it and what it runs.

  FluidNC keeps config files (YAML) on its local filesystem and loads one at
  boot, named by `$Config/Filename`. This module lists, shows, writes
  (`upload/4`: XModem on hardware), switches (`activate/2`: choose, then
  restart) and deletes them, reads the running config (`$CD`) and gets or
  sets one setting live (`$/path=value`, read back, since FluidNC answers
  `ok` even when it didn't apply a value). Wiring (`CNC.Boards.wiring?/1`)
  isn't set live. Before a file is rewritten or deleted its text goes into
  the controller's history (in the app's database).

  The happy path on top of this is `CNC.Controllers.Profiles`: named sets
  of values, each rendered (board + profile) into its own file.

  Everything goes through `CNC.Machine.request/3`, so it needs the machine
  connected and `:idle` or `:alarm`.
  """

  alias CNC.Controllers.Yaml
  alias CNC.Machine

  @type file :: %{name: String.t(), size: non_neg_integer}
  @typedoc """
  One change to a controller's config, in its history: when, why (`reason`,
  e.g. "Switched to profile Fast"), the file written (`file`, `text`: the
  file as it was written, so it can be restored; both `nil` for a live-only
  change) and what changed (`diff`).
  """
  @type revision :: %{
          version: pos_integer,
          at: DateTime.t(),
          reason: String.t(),
          file: String.t() | nil,
          text: String.t() | nil,
          diff: [%{path: String.t(), from: String.t() | nil, to: String.t() | nil}]
        }

  @typedoc "Where to record a change: `{db, controller_id, reason}`, or nil to not record it."
  @type recording :: {GenServer.server(), String.t(), String.t()} | nil

  @history_max 50

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

  @doc "Delete a config file (not the one loaded at boot)."
  @spec delete(GenServer.server(), String.t()) :: :ok | {:error, term}
  def delete(machine, name) do
    with {:ok, name} <- valid_name(name),
         {:ok, %{active: active}} <- files(machine),
         false <- name == active && {:error, :active},
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
  def parse(text), do: text |> Yaml.parse() |> Yaml.leaves()

  @doc """
  The controller's wiring against its board's pin map (`CNC.Boards.config/1`):
  how many wiring settings were compared (only ones both mention) and where
  they differ, `[%{path, board, controller}]`. A difference usually means the
  wrong board, or wiring changed on purpose.
  """
  @spec wiring_check(atom, [{String.t(), String.t()}]) ::
          %{checked: non_neg_integer, differences: [map]}
  def wiring_check(board, running_settings) do
    running = Map.new(running_settings)

    compared =
      for {path, expected} <- parse(CNC.Boards.config(board)),
          CNC.Boards.wiring?(path),
          actual = running[path],
          actual != nil,
          do: {path, expected, actual}

    %{
      checked: length(compared),
      differences:
        for(
          {path, expected, actual} <- compared,
          not same_wiring?(path, expected, actual),
          do: %{path: path, board: expected, controller: actual}
        )
    }
  end

  defp same_wiring?(path, a, b) do
    if String.ends_with?(path, "_pin"),
      do: CNC.Boards.normalize_pin(a) == CNC.Boards.normalize_pin(b),
      else: same?(a, b)
  end

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
  Write a whole config file onto the controller (`CNC.Machine.upload/4`:
  XModem on hardware). To use it, switch to it (`activate/2`). With
  `{db, controller_id, reason}` the change goes into the controller's
  history: the reason, the diff against what the file held, and the file.
  """
  @spec upload(GenServer.server(), String.t(), String.t(), recording) ::
          {:ok, String.t()} | {:error, term}
  def upload(machine, name, text, record \\ nil) do
    with {:ok, name} <- valid_name(name),
         {:ok, before} <- current_text(machine, name, record),
         {:ok, _bytes} <- Machine.upload(machine, name, text) do
      with {db, id, reason} <- record do
        record(db, id, %{reason: reason, file: name, text: text, diff: diff_texts(before, text)})
      end

      {:ok, name}
    end
  end

  # What a file holds before it's rewritten (nil if it isn't there): only
  # needed when the change is recorded.
  defp current_text(_machine, _name, nil), do: {:ok, nil}

  defp current_text(machine, name, _record) do
    case show(machine, name) do
      {:ok, text} -> {:ok, text}
      {:error, :not_found} -> {:ok, nil}
      error -> error
    end
  end

  @doc """
  Write a revision's file back (it becomes a new revision, "Restored ...").
  If it's the file the controller loads, it takes effect after a restart.
  """
  @spec restore(GenServer.server(), GenServer.server(), String.t(), revision) ::
          {:ok, String.t()} | {:error, term}
  def restore(_machine, _db, _id, %{text: nil}), do: {:error, :no_file}

  def restore(machine, db, id, %{file: file, text: text} = revision) do
    reason = "Restored v#{revision.version} (#{revision.reason})"
    upload(machine, file, text, {db, id, reason})
  end

  @doc "Write a board's default config (`CNC.Boards.config/1`) onto the controller as a file."
  @spec write_board_default(GenServer.server(), atom, String.t()) ::
          {:ok, String.t()} | {:error, term}
  def write_board_default(machine, board, name),
    do: upload(machine, name, CNC.Boards.config(board))

  @doc """
  Add a change to a controller's history (newest first, the last
  #{@history_max} kept). For changes that write no file (live only), `file`
  and `text` are nil.
  """
  def record(db, id, change) do
    history = history(db, id)

    version =
      case history do
        [%{version: v} | _] -> v + 1
        _ -> length(history) + 1
      end

    entry = Map.merge(%{file: nil, text: nil, diff: []}, change)
    entry = Map.merge(entry, %{at: DateTime.utc_now(:second), version: version})
    CubDB.put(db, {:config_history, id}, Enum.take([entry | history], @history_max))
  end

  @doc "A controller's config history: every recorded change, newest first."
  @spec history(GenServer.server(), String.t()) :: [revision]
  def history(db, id) do
    entries = CubDB.get(db, {:config_history, id}, [])
    count = length(entries)

    for {entry, i} <- Enum.with_index(entries) do
      # Entries from before revisions had reasons, diffs and versions
      Map.merge(
        %{
          reason: Map.get(entry, :why, "Earlier version"),
          diff: [],
          file: nil,
          text: nil,
          version: count - i
        },
        entry
      )
    end
  end

  @doc """
  What changed between two config texts, by setting (`nil` text is an
  empty file): `[%{path, from, to}]`, numbers compared as numbers.
  """
  @spec diff_texts(String.t() | nil, String.t()) :: [map]
  def diff_texts(old, new) do
    from = Map.new(parse(old || ""))
    to = Map.new(parse(new || ""))

    # (A tuple, not two bindings: a nil binding would filter the element out.)
    for path <- Enum.sort(Enum.uniq(Map.keys(from) ++ Map.keys(to))),
        {x, y} = {from[path], to[path]},
        x == nil or y == nil or not same?(x, y),
        do: %{path: path, from: x, to: y}
  end

  @doc "Forget a controller's profiles and history (it was removed)."
  def forget(db, id),
    do: CubDB.delete_multi(db, [{:config_history, id}, {:profiles, id}])

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

  @doc "Two setting values mean the same: numbers as numbers (FluidNC prints 900 as 900.000), text in any case."
  def same?(a, b) do
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

  @doc "A value that's safe to send as `$/path=value` (one line, no `=`)."
  def valid_value?(value), do: match?({:ok, _}, valid_value(value))

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
