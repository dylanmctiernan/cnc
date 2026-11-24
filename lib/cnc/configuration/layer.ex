defmodule CNC.Configuration.Layer do
  @moduledoc """
  A layer of configuration kept in the app (the build, a controller's
  wiring): its values, and a version per change with its reason, its diff
  and the values after (newest first). Stored under a CubDB key.
  """

  alias CNC.Configuration.Values

  @type revision :: %{
          version: pos_integer,
          at: DateTime.t(),
          reason: String.t(),
          diff: [map],
          values: map
        }
  @type t :: %{values: map, history: [revision]}

  @history_max 50

  @doc "The layer under `key`, or nil if there's none yet."
  @spec get(GenServer.server(), term) :: t | nil
  def get(db, key), do: CubDB.get(db, key)

  @doc "Its values (empty if there's none yet)."
  def values(db, key), do: (get(db, key) || %{values: %{}}).values

  @doc "Its versions, newest first."
  def history(db, key), do: (get(db, key) || %{history: []}).history

  @doc "Create it with these values (version 1), unless it's there."
  def ensure(db, key, values, reason) do
    if get(db, key) == nil, do: put(db, key, revise(empty(), values, reason)), else: :ok
  end

  @doc "Merge in changed values, as a new version (nothing changed: no version)."
  def change(db, key, changes, reason),
    do: replace(db, key, Map.merge(values(db, key), changes), reason)

  @doc "Replace the values, as a new version (the same values: no version)."
  def replace(db, key, values, reason) do
    layer = get(db, key) || empty()

    if Values.diff_maps(layer.values, values) == [],
      do: :ok,
      else: put(db, key, revise(layer, values, reason))
  end

  @doc "Put an earlier version's values back, as a new version."
  def restore(db, key, index) do
    case Enum.at(history(db, key), index) do
      %{values: values, version: v} -> replace(db, key, values, "Restored v#{v}")
      nil -> {:error, :not_found}
    end
  end

  def delete(db, key), do: CubDB.delete(db, key)

  @doc "A new version: why, what changed, and the values after."
  def revise(layer, values, reason) do
    version =
      case layer.history do
        [%{version: v} | _] -> v + 1
        h -> length(h) + 1
      end

    entry = %{
      version: version,
      at: DateTime.utc_now(:second),
      reason: reason,
      diff: Values.diff_maps(layer.values, values),
      values: values
    }

    %{layer | values: values, history: Enum.take([entry | layer.history], @history_max)}
  end

  defp empty, do: %{values: %{}, history: []}
  defp put(db, key, layer), do: CubDB.put(db, key, layer)
end
