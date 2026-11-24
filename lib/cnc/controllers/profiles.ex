defmodule CNC.Controllers.Profiles do
  @moduledoc """
  Profiles: named sets of a controller's editable settings (everything but
  wiring), the way to tune and to keep variations.

  Profiles live in the app (CubDB, per controller), with the one selected.
  The controller holds a single config file, `config.yaml`, generated from
  the selected profile: the board's default config (`CNC.Boards.config/1`,
  which owns the wiring) with the profile's values set (`render/2`).
  Switching writes the other profile into that file and restarts the
  controller. Every earlier version of the file is kept in the app's
  history (`CNC.Controllers.Config.history/2`).

  The controller's file is read back and checked against the selected
  profile (`check/3`): it matches, or it differs (edited elsewhere, an
  earlier version restored, another file loaded directly), and then either
  side can win: write the profile again, or take the file's values into the
  profile. Editing a value applies it live, stores it in the profile and
  rewrites the file. `drift/3` finds live values the profile doesn't have
  (changed in the console).

  A controller seen for the first time gets a "Default" profile from what
  it runs. Nothing is written until a profile is written or switched to.
  """

  alias CNC.Boards
  alias CNC.Controllers.{Config, Yaml}

  @type profile :: %{id: String.t(), name: String.t(), values: map}

  @key :profiles
  # The one file on the controller
  @config_file "config.yaml"

  @doc "The config file the app keeps on the controller."
  def file, do: @config_file

  @doc "Whether a setting belongs in a profile (not wiring, not the board's label)."
  def editable?(path), do: path not in ["board", "name", "meta"] and not Boards.wiring?(path)

  @doc "A controller's profiles, in the order made."
  @spec list(GenServer.server(), String.t()) :: [profile]
  def list(db, id), do: stored(db, id).profiles

  @doc "The selected profile (the one the controller's file should hold), or nil."
  def selected(db, id) do
    s = stored(db, id)
    Enum.find(s.profiles, &(&1.id == s.selected))
  end

  @doc """
  What the last `check/3` found, for showing without asking the controller:
  `%{name: profile, matches?: boolean}`, or nil.
  """
  def last_seen(db, id), do: stored(db, id).seen

  @doc """
  First contact: with no profiles yet, make "Default" from what the
  controller runs, and select it. Nothing is written.
  """
  @spec ensure(GenServer.server(), GenServer.server(), String.t()) :: :ok | {:error, term}
  def ensure(machine, db, id) do
    s = stored(db, id)

    cond do
      s.profiles == [] ->
        with {:ok, running} <- Config.running(machine) do
          profile = %{id: new_id(), name: "Default", values: editable(running)}
          put(db, id, %{s | profiles: [profile], selected: profile.id})
        end

      not Enum.any?(s.profiles, &(&1.id == s.selected)) ->
        put(db, id, %{s | selected: hd(s.profiles).id})

      true ->
        :ok
    end
  end

  @doc """
  The controller's file against the selected profile: which file it loaded,
  whether it's the app's file holding exactly what the profile writes, and
  the values that differ (`[%{path, profile, controller}]`; `controller` is
  `nil` for a setting the file leaves out, where FluidNC uses its default).
  """
  @spec check(GenServer.server(), GenServer.server(), map) :: {:ok, map} | {:error, term}
  def check(machine, db, controller) do
    with {:ok, %{active: loaded}} <- Config.files(machine),
         %{} = profile <- selected(db, controller.id) || {:error, :no_profile},
         {:ok, text} <- Config.show(machine, loaded || @config_file) do
      in_file = editable(text)
      # What the profile writes: the board's defaults plus its values.
      expected = editable(render(controller.board, profile))

      # (A tuple, not two bindings: in a comprehension a binding to nil
      # filters the element out, and a value missing on one side counts.)
      differences =
        for path <- Enum.sort(Enum.uniq(Map.keys(expected) ++ Map.keys(in_file))),
            {want, have} = {expected[path], in_file[path]},
            want == nil or have == nil or not Config.same?(want, have),
            do: %{path: path, profile: want, controller: have}

      matches? = loaded == @config_file and differences == []
      remember(db, controller.id, %{name: profile.name, matches?: matches?})

      {:ok,
       %{
         profile: profile,
         loaded: loaded,
         override?: loaded != @config_file,
         matches?: matches?,
         written_by_app?: String.starts_with?(text, "# Written by the CNC app"),
         differences: differences
       }}
    end
  end

  @doc """
  A new profile: a copy of another (`from: profile_id`) or the board's
  default values (`from: :board`). Nothing is written until switched to.
  """
  @spec create(GenServer.server(), String.t(), String.t(), atom, String.t() | :board) ::
          {:ok, profile} | {:error, term}
  def create(db, id, name, board, from) do
    name = String.trim(name)
    profiles = list(db, id)

    values =
      case from do
        :board -> editable(Boards.config(board))
        pid -> Enum.find_value(profiles, &(&1.id == pid && &1.values))
      end

    cond do
      name == "" ->
        {:error, :name_required}

      Enum.any?(profiles, &(String.downcase(&1.name) == String.downcase(name))) ->
        {:error, :exists}

      values == nil ->
        {:error, :not_found}

      true ->
        profile = %{id: new_id(), name: name, values: values}
        put(db, id, %{stored(db, id) | profiles: profiles ++ [profile]})
        {:ok, profile}
    end
  end

  @doc "Rename a profile."
  def rename(db, id, pid, name) do
    name = String.trim(name)
    profiles = list(db, id)

    cond do
      name == "" ->
        {:error, :name_required}

      Enum.any?(profiles, &(&1.id != pid and String.downcase(&1.name) == String.downcase(name))) ->
        {:error, :exists}

      true ->
        update(db, id, pid, &%{&1 | name: name})
    end
  end

  @doc "Delete a profile (not the selected one)."
  def delete(db, id, pid) do
    s = stored(db, id)

    if s.selected == pid,
      do: {:error, :in_use},
      else: put(db, id, %{s | profiles: Enum.reject(s.profiles, &(&1.id == pid))})
  end

  @doc """
  Switch to a profile (or write the selected one again): its values go into
  the controller's file, which is chosen for boot, and the controller
  restarts with it (and comes back locked). The file's previous text goes
  into the history.
  """
  @spec switch(GenServer.server(), GenServer.server(), map, String.t()) :: :ok | {:error, term}
  def switch(machine, db, controller, pid) do
    with %{} = profile <- find(db, controller.id, pid) || {:error, :not_found},
         {:ok, _} <- write(machine, db, controller, profile) do
      put(db, controller.id, %{stored(db, controller.id) | selected: pid})
      Config.activate(machine, @config_file)
    end
  end

  @doc """
  Keep what the controller runs in the selected profile (its file was
  changed elsewhere, an earlier version restored, a file uploaded, and
  that's the one to keep): the running values, which include FluidNC's
  defaults for whatever the file leaves out, become the profile's; then the
  profile is written and the controller restarts, so file and profile agree.
  """
  def take_file(machine, db, controller) do
    with %{} = profile <- selected(db, controller.id) || {:error, :no_profile},
         {:ok, running} <- Config.running(machine) do
      profile = %{profile | values: editable(running)}
      update(db, controller.id, profile.id, fn _ -> profile end)
      switch(machine, db, controller, profile.id)
    end
  end

  @doc """
  Change settings in the selected profile: each is set live and read back
  (refused: wiring, or what the controller didn't apply), stored, then the
  controller's file is rewritten once. Only while the controller runs the
  app's file (not a file loaded directly).
  """
  @spec set(GenServer.server(), GenServer.server(), map, [{String.t(), String.t()}]) ::
          {:ok, %{applied: map, errors: map}} | {:error, term}
  def set(machine, db, controller, changes) do
    with {:ok, %{active: @config_file}} <- Config.files(machine),
         %{} = profile <- selected(db, controller.id) || {:error, :no_profile} do
      {applied, errors} =
        Enum.reduce(changes, {%{}, %{}}, fn {path, value}, {ok, bad} ->
          path = clean(path)

          with true <- editable?(path) || {:error, :wiring},
               {:ok, now} <- Config.set(machine, path, value) do
            {Map.put(ok, path, now), bad}
          else
            {:error, reason} -> {ok, Map.put(bad, path, reason)}
          end
        end)

      written =
        if applied == %{} do
          :ok
        else
          profile = %{profile | values: Map.merge(profile.values, applied)}
          update(db, controller.id, profile.id, fn _ -> profile end)
          write(machine, db, controller, profile)
        end

      case written do
        {:error, reason} -> {:error, {:not_written, reason}}
        _ -> {:ok, %{applied: applied, errors: errors}}
      end
    else
      {:ok, %{active: _other}} -> {:error, :override}
      other -> other
    end
  end

  @doc """
  Change values in a profile that isn't running: stored only (they reach
  the controller when it's switched to). Checked here, since the
  controller can't: editable settings only, and a number stays a number.
  The selected profile is changed with `set/4` (live).
  """
  @spec edit(GenServer.server(), String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, %{applied: map, errors: map}} | {:error, term}
  def edit(db, id, pid, changes) do
    s = stored(db, id)

    with %{} = profile <- find(db, id, pid) || {:error, :not_found},
         false <- s.selected == pid && {:error, :selected} do
      {applied, errors} =
        Enum.reduce(changes, {%{}, %{}}, fn {path, value}, {ok, bad} ->
          path = clean(path)
          value = String.trim(value)
          old = profile.values[path]

          cond do
            not editable?(path) -> {ok, Map.put(bad, path, :wiring)}
            not Config.valid_value?(value) -> {ok, Map.put(bad, path, :invalid_value)}
            number?(old) and not number?(value) -> {ok, Map.put(bad, path, :not_a_number)}
            true -> {Map.put(ok, path, value), bad}
          end
        end)

      if applied != %{},
        do: update(db, id, pid, &%{&1 | values: Map.merge(&1.values, applied)})

      {:ok, %{applied: applied, errors: errors}}
    end
  end

  defp number?(nil), do: false
  defp number?(v), do: match?({_, ""}, Float.parse(v))

  defp clean(path),
    do:
      path |> String.trim() |> String.trim_leading("$/") |> String.trim("/") |> String.downcase()

  @doc """
  Live values the selected profile doesn't have (changed in the console,
  say): `[%{path, profile, controller}]`.
  """
  @spec drift(GenServer.server(), GenServer.server(), String.t()) ::
          {:ok, [map]} | {:error, term}
  def drift(machine, db, id) do
    with %{values: values} <- selected(db, id) || {:error, :no_profile},
         {:ok, running} <- Config.running(machine) do
      now = Map.new(Config.parse(running))

      differences =
        for {path, want} <- Enum.sort(values),
            have = now[path],
            have != nil and not Config.same?(have, want),
            do: %{path: path, profile: want, controller: have}

      {:ok, differences}
    end
  end

  @doc "Take the live values into the selected profile, and write its file."
  def keep_drift(machine, db, controller) do
    with {:ok, list} <- drift(machine, db, controller.id),
         %{} = profile <- selected(db, controller.id) do
      values = Map.merge(profile.values, Map.new(list, &{&1.path, &1.controller}))
      profile = %{profile | values: values}
      update(db, controller.id, profile.id, fn _ -> profile end)
      with {:ok, _} <- write(machine, db, controller, profile), do: :ok
    end
  end

  @doc "Put the selected profile's values back on the controller (live)."
  def put_back(machine, db, id) do
    with {:ok, list} <- drift(machine, db, id) do
      Enum.each(list, &Config.set(machine, &1.path, &1.profile))
    end
  end

  @doc """
  The escape hatch: a config file of your own replaces the controller's
  (its current text goes into the history) and the controller restarts with
  it. `check/3` then shows how it differs from the selected profile.
  """
  @spec replace_file(GenServer.server(), GenServer.server(), map, String.t()) ::
          :ok | {:error, term}
  def replace_file(machine, db, controller, text) do
    with true <- Config.parse(text) != [] || {:error, :not_a_config},
         {:ok, _} <- Config.upload(machine, @config_file, text, {db, controller.id}) do
      Config.activate(machine, @config_file)
    end
  end

  @doc "The file a profile makes for a board: the board's default config with the profile's values."
  @spec render(atom, profile) :: String.t()
  def render(board, profile) do
    tree =
      profile.values
      |> Enum.sort()
      |> Enum.reduce(Yaml.parse(Boards.config(board)), fn {path, v}, tree ->
        Yaml.put(tree, path, v)
      end)

    """
    # Written by the CNC app: board #{Boards.label(board)}, profile "#{profile.name}".
    # Change it from the app (Controllers > Configuration); edits here show
    # there as differences from the profile.

    """ <> Yaml.render(tree)
  end

  ## Storage

  defp write(machine, db, controller, profile),
    do:
      Config.upload(machine, @config_file, render(controller.board, profile), {db, controller.id})

  defp editable(text), do: for({p, v} <- Config.parse(text), editable?(p), into: %{}, do: {p, v})

  defp find(db, id, pid), do: Enum.find(list(db, id), &(&1.id == pid))

  defp update(db, id, pid, fun) do
    profiles = Enum.map(list(db, id), &if(&1.id == pid, do: fun.(&1), else: &1))
    put(db, id, %{stored(db, id) | profiles: profiles})
  end

  defp remember(db, id, seen) do
    s = stored(db, id)
    if s.seen != seen, do: put(db, id, %{s | seen: seen})
  end

  # Profiles stored before (one file each) carry a :file; it's ignored.
  defp stored(db, id) do
    s = Map.merge(%{profiles: [], selected: nil, seen: nil}, CubDB.get(db, {@key, id}, %{}))
    %{s | profiles: Enum.map(s.profiles, &Map.take(&1, [:id, :name, :values]))}
  end

  defp put(db, id, data), do: CubDB.put(db, {@key, id}, data)

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
end
