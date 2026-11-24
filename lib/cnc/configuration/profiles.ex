defmodule CNC.Configuration.Profiles do
  @moduledoc """
  The machine's profiles: named sets of how it's run (rates, acceleration,
  homing speeds, junction deviation, soft limits...), one of them selected.
  Like the build they belong to the machine, so they carry over when
  another controller takes over. Every change to a profile is a version,
  with its reason, its diff and its values after.

  A plain store. Changes that also reach the controller (switching,
  changing the selected profile live) go through `CNC.Configuration`.
  """

  alias CNC.Boards
  alias CNC.Configuration.{Build, Layer, Values}

  @type profile :: %{id: String.t(), name: String.t(), values: map, history: [Layer.revision()]}

  @key :profiles

  @doc "Whether a value belongs in a profile (see `CNC.Configuration.Build.layer/1`)."
  def editable?(path), do: Build.layer(path) == :profile

  @doc "The machine's profiles, in the order made."
  @spec list(GenServer.server()) :: [profile]
  def list(db), do: stored(db).profiles

  @doc "The selected profile, or nil."
  def selected(db) do
    s = stored(db)
    Enum.find(s.profiles, &(&1.id == s.selected))
  end

  def find(db, pid), do: Enum.find(list(db), &(&1.id == pid))

  @doc "Make a profile the selected one (`CNC.Configuration.switch/5` writes it)."
  def select(db, pid), do: put(db, %{stored(db) | selected: pid})

  @doc "With none yet: a \"Default\" profile with these values, selected. Else make sure one is selected."
  def ensure(db, values) do
    s = stored(db)

    cond do
      s.profiles == [] ->
        p = new_profile("Default", values, "Made from what the controller ran")
        put(db, %{s | profiles: [p], selected: p.id})

      not Enum.any?(s.profiles, &(&1.id == s.selected)) ->
        put(db, %{s | selected: hd(s.profiles).id})

      true ->
        :ok
    end
  end

  @doc """
  A new profile: a copy of another (`from: profile_id`) or the board's
  default values (`from: :board`). Nothing reaches the controller until
  it's switched to.
  """
  @spec create(GenServer.server(), String.t(), atom, String.t() | :board) ::
          {:ok, profile} | {:error, term}
  def create(db, name, board, from) do
    name = String.trim(name)
    profiles = list(db)

    {values, reason} =
      case from do
        :board ->
          {Build.pick(Boards.config(board), :profile),
           "Made from the #{Boards.label(board)} default"}

        pid ->
          case find(db, pid) do
            nil -> {nil, nil}
            p -> {p.values, "Made as a copy of #{p.name}"}
          end
      end

    cond do
      name == "" ->
        {:error, :name_required}

      Enum.any?(profiles, &(String.downcase(&1.name) == String.downcase(name))) ->
        {:error, :exists}

      values == nil ->
        {:error, :not_found}

      true ->
        profile = new_profile(name, values, reason)
        put(db, %{stored(db) | profiles: profiles ++ [profile]})
        {:ok, profile}
    end
  end

  @doc "Rename a profile (a version with no values changed)."
  def rename(db, pid, name) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:error, :name_required}

      Enum.any?(list(db), &(&1.id != pid and String.downcase(&1.name) == String.downcase(name))) ->
        {:error, :exists}

      true ->
        update(db, pid, fn p ->
          if p.name == name,
            do: p,
            else: Layer.revise(%{p | name: name}, p.values, "Renamed from #{p.name}")
        end)
    end
  end

  @doc "Delete a profile (not the selected one)."
  def delete(db, pid) do
    s = stored(db)

    if s.selected == pid,
      do: {:error, :in_use},
      else: put(db, %{s | profiles: Enum.reject(s.profiles, &(&1.id == pid))})
  end

  @doc "Merge values into a profile, as a new version."
  def change(db, pid, changes, reason) when changes != %{},
    do: update(db, pid, &Layer.revise(&1, Map.merge(&1.values, changes), reason))

  def change(_db, _pid, _changes, _reason), do: :ok

  @doc "Replace a profile's values, as a new version."
  def replace(db, pid, values, reason), do: update(db, pid, &Layer.revise(&1, values, reason))

  @doc """
  Change values in a profile that isn't running: stored only (they reach
  the controller when it's switched to). Checked here, since the
  controller can't: profile values only (the build and wiring are the same
  for every profile), and a number stays a number.
  """
  @spec edit(GenServer.server(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, %{applied: map, errors: map}} | {:error, term}
  def edit(db, pid, changes) do
    with %{} = profile <- find(db, pid) || {:error, :not_found},
         false <- stored(db).selected == pid && {:error, :selected} do
      {applied, errors} =
        Enum.reduce(changes, {%{}, %{}}, fn {path, value}, {ok, bad} ->
          path = clean(path)

          with true <- editable?(path) || {:error, :not_profile_value},
               {:ok, v} <- check_value(value, profile.values[path]) do
            {Map.put(ok, path, v), bad}
          else
            {:error, reason} -> {ok, Map.put(bad, path, reason)}
          end
        end)

      change(db, pid, applied, "Edited")
      {:ok, %{applied: applied, errors: errors}}
    end
  end

  @doc "A value checked without the controller: safe to send, and a number stays a number."
  def check_value(value, old) do
    with {:ok, value} <- Values.valid_value(value) do
      if number?(old) and not number?(value), do: {:error, :not_a_number}, else: {:ok, value}
    end
  end

  @doc "What restoring a profile's version would change: `[%{path, from, to}]`."
  def restore_diff(db, pid, index) do
    with %{} = profile <- find(db, pid),
         %{values: values} <- Enum.at(profile.history, index) do
      Values.diff_maps(profile.values, values)
    else
      _ -> []
    end
  end

  @doc "How two profiles differ: `[%{path, from, to}]` (from `a` to `b`)."
  def diff(a, b), do: Values.diff_maps(a.values, b.values)

  @doc "A path as typed (`$/Axes/X/...`) as FluidNC takes it."
  def clean(path),
    do:
      path |> String.trim() |> String.trim_leading("$/") |> String.trim("/") |> String.downcase()

  @doc """
  Profiles were kept per controller before, with build and wiring values in
  them: the first controller to come through hands them to the machine,
  keeping only profile values in each.
  """
  def migrate(db, controller_id) do
    case {CubDB.get(db, @key), CubDB.get(db, {@key, controller_id})} do
      {nil, %{profiles: old} = data} when old != [] ->
        profiles =
          for p <- old do
            values = for {path, v} <- p.values, editable?(path), into: %{}, do: {path, v}

            %{history: []}
            |> Map.merge(Map.take(p, [:id, :name, :history]))
            |> Map.put(:values, values)
          end

        put(db, %{profiles: profiles, selected: data[:selected]})
        CubDB.delete(db, {@key, controller_id})

      _ ->
        :ok
    end
  end

  defp number?(nil), do: false
  defp number?(v), do: match?({_, ""}, Float.parse(v))

  defp new_profile(name, values, reason),
    do: Layer.revise(%{id: new_id(), name: name, values: %{}, history: []}, values, reason)

  defp update(db, pid, fun) do
    profiles = Enum.map(list(db), &if(&1.id == pid, do: fun.(&1), else: &1))
    put(db, %{stored(db) | profiles: profiles})
  end

  defp stored(db), do: Map.merge(%{profiles: [], selected: nil}, CubDB.get(db, @key, %{}))
  defp put(db, data), do: CubDB.put(db, @key, data)

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
end
