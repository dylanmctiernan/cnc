defmodule CNC.Configuration.History do
  @moduledoc """
  Every change to a controller's config, newest first: a version each, with
  when, why (`reason`, e.g. "Switched to profile Fast"), what changed
  (`diff`) and the file as written (`file`, `text`; both nil for a
  live-only change), so any version can be viewed or restored. Restoring is
  itself a new version.
  """

  alias CNC.Configuration.FluidNC

  @type revision :: %{
          version: pos_integer,
          at: DateTime.t(),
          reason: String.t(),
          file: String.t() | nil,
          text: String.t() | nil,
          diff: [%{path: String.t(), from: String.t() | nil, to: String.t() | nil}]
        }

  @history_max 50

  defp key(id), do: {:config_history, id}

  @doc """
  Add a change (the last #{@history_max} are kept). For a live-only change
  `file` and `text` are left nil.
  """
  def record(db, id, change) do
    history = list(db, id)

    version =
      case history do
        [%{version: v} | _] -> v + 1
        _ -> length(history) + 1
      end

    entry =
      %{file: nil, text: nil, diff: []}
      |> Map.merge(change)
      |> Map.merge(%{at: DateTime.utc_now(:second), version: version})

    CubDB.put(db, key(id), Enum.take([entry | history], @history_max))
  end

  @doc "A controller's config history, newest first."
  @spec list(GenServer.server(), String.t()) :: [revision]
  def list(db, id) do
    entries = CubDB.get(db, key(id), [])
    count = length(entries)

    for {entry, i} <- Enum.with_index(entries) do
      # Entries from before versions had reasons and diffs
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

  @doc "Write a version's file back to the controller (a new version, \"Restored v4\")."
  @spec restore(GenServer.server(), GenServer.server(), String.t(), revision) ::
          {:ok, String.t()} | {:error, term}
  def restore(_machine, _db, _id, %{text: nil}), do: {:error, :no_file}

  def restore(machine, db, id, %{file: file, text: text} = revision) do
    reason = "Restored v#{revision.version} (#{revision.reason})"
    FluidNC.upload(machine, file, text, {db, id, reason})
  end

  @doc "Forget a controller's history (it was removed)."
  def forget(db, id), do: CubDB.delete(db, key(id))
end
