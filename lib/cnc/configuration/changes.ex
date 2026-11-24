defmodule CNC.Configuration.Changes do
  @moduledoc """
  The staged changeset: edits made anywhere in the configuration (the build,
  a controller's wiring, any profile) that haven't been applied yet. Kept in
  the app's database, so every screen sees the same pending changes, and
  applied together by `CNC.Configuration.apply/4`.

  A change is `%{part, target, path, from, to}`: the part (`:build`,
  `:wiring`, `:profile`), whose (a controller id for wiring, a profile id
  for a profile, nil for the build), the value's path, what it was when
  staged and what it becomes. Staging a value back to what it was drops it.
  """

  alias CNC.Configuration.Values

  @key :staged_changes

  @type change :: %{
          part: :build | :wiring | :profile,
          target: String.t() | nil,
          path: String.t(),
          from: String.t() | nil,
          to: String.t()
        }

  @doc "The staged changes, in the order staged."
  @spec list(GenServer.server()) :: [change]
  def list(db), do: CubDB.get(db, @key, [])

  @doc "A change's identity: one staged value per part, target and path."
  def key(%{part: part, target: target, path: path}), do: "#{part}:#{target}:#{path}"

  @doc """
  Stage changes (replacing any staged for the same value). One whose `to`
  is what it was (`from`) is dropped instead.
  """
  def stage(db, changes) do
    staged =
      Enum.reduce(changes, list(db), fn change, staged ->
        rest = Enum.reject(staged, &(key(&1) == key(change)))
        # The value it had before any staging is the one to compare with
        from = Enum.find_value(staged, change.from, &(key(&1) == key(change) && &1.from))
        change = %{change | from: from}

        if from != nil and Values.same?(from, change.to), do: rest, else: rest ++ [change]
      end)

    put(db, staged)
  end

  @doc "Drop staged changes by key."
  def drop(db, keys), do: put(db, Enum.reject(list(db), &(key(&1) in keys)))

  @doc "Drop them all."
  def clear(db), do: put(db, [])

  @doc "Receive `{:configuration_changes, list}` when the staged changes change."
  def subscribe(db), do: Phoenix.PubSub.subscribe(CNC.PubSub, topic(db))

  defp put(db, staged) do
    :ok = CubDB.put(db, @key, staged)
    Phoenix.PubSub.broadcast(CNC.PubSub, topic(db), {:configuration_changes, staged})
    :ok
  end

  # One topic per database: screens on the same machine share it.
  defp topic(db), do: "configuration-changes:#{inspect(db)}"
end
