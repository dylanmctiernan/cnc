defmodule CNC.Controllers.Profiles do
  @moduledoc """
  Profiles: named sets of a controller's editable settings (everything but
  wiring), the way to tune and to keep variations.

  Profiles live in the app (CubDB, per controller), with the one selected.
  The controller holds a single config file, `config.yaml`, generated from
  the selected profile: the board's wiring (`CNC.Boards.config/1`) and
  exactly the profile's values (`render/2`), nothing merged in; a setting
  the profile doesn't have is left to FluidNC's own default. The board's
  default values are only a starting point, copied into a profile made
  from them.
  Switching writes the other profile into that file and restarts the
  controller.

  Two histories, each change with its reason and diff:

    * the controller's (`CNC.Controllers.Config.history/2`): every change to
      its config (switching, settings changed, a file uploaded or pasted, a
      version restored, values put back), with the file as written;
    * each profile's (`profile.history`): every change to its values (made,
      edited, changed live, kept from the controller, restored), with the
      values after, so it can be restored (`restore/5`, itself a revision).

  The controller's file is read back and checked against the selected
  profile (`check/3`): it matches, or it differs (edited elsewhere, a version
  restored, a file of your own), and then either side can win: write the
  profile again, or take the controller's values into it. An override
  (`replace_file/5`) puts your own file in place of the profile's.

  A controller seen for the first time gets a "Default" profile from what
  it runs. Nothing is written until a profile is written or switched to.
  """

  alias CNC.Boards
  alias CNC.Controllers.{Config, Yaml}

  @type revision :: %{
          version: pos_integer,
          at: DateTime.t(),
          reason: String.t(),
          diff: [map],
          values: map
        }
  @type profile :: %{id: String.t(), name: String.t(), values: map, history: [revision]}

  @key :profiles
  # The one file on the controller
  @config_file "config.yaml"
  @history_max 50

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
          profile = new_profile("Default", editable(running), "Made from what the controller ran")
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
      # What the profile writes: exactly its values (wiring is checked
      # against the board on its own).
      expected = profile.values

      differences =
        for %{path: path, from: want, to: have} <- diff_maps(expected, in_file),
            do: %{path: path, profile: want, controller: have}

      matches? = loaded == @config_file and differences == []
      remember(db, controller.id, %{name: profile.name, matches?: matches?})

      {:ok,
       %{
         profile: profile,
         loaded: loaded,
         text: text,
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

    {values, reason} =
      case from do
        :board ->
          {editable(Boards.config(board)), "Made from the board's default"}

        pid ->
          case Enum.find(profiles, &(&1.id == pid)) do
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
        put(db, id, %{stored(db, id) | profiles: profiles ++ [profile]})
        {:ok, profile}
    end
  end

  @doc "Rename a profile (a revision with no settings changed)."
  def rename(db, id, pid, name) do
    name = String.trim(name)
    profiles = list(db, id)

    cond do
      name == "" ->
        {:error, :name_required}

      Enum.any?(profiles, &(&1.id != pid and String.downcase(&1.name) == String.downcase(name))) ->
        {:error, :exists}

      true ->
        update(db, id, pid, fn p ->
          if p.name == name,
            do: p,
            else: revise(%{p | name: name}, p.values, "Renamed from #{p.name}")
        end)
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
  restarts with it (and comes back locked). Recorded in the controller's
  history (`reason` defaults to "Switched to profile X" / "Wrote profile X").
  """
  @spec switch(GenServer.server(), GenServer.server(), map, String.t(), String.t() | nil) ::
          :ok | {:error, term}
  def switch(machine, db, controller, pid, reason \\ nil) do
    with %{} = profile <- find(db, controller.id, pid) || {:error, :not_found} do
      reason =
        reason ||
          if stored(db, controller.id).selected == pid,
            do: "Wrote profile #{profile.name}",
            else: "Switched to profile #{profile.name}"

      with {:ok, _} <- write(machine, db, controller, profile, reason) do
        put(db, controller.id, %{stored(db, controller.id) | selected: pid})
        Config.activate(machine, @config_file)
      end
    end
  end

  @doc """
  Keep what the controller runs in the selected profile (its file was
  changed elsewhere, a version restored, a file of your own, and that's the
  one to keep): the running values, which include FluidNC's defaults for
  whatever the file leaves out, become the profile's; then the profile is
  written and the controller restarts, so file and profile agree.
  """
  def take_file(machine, db, controller) do
    with %{} = profile <- selected(db, controller.id) || {:error, :no_profile},
         {:ok, running} <- Config.running(machine) do
      update(db, controller.id, profile.id, fn p ->
        revise(p, editable(running), "Kept the controller's values")
      end)

      switch(
        machine,
        db,
        controller,
        profile.id,
        "Kept the controller's values in profile #{profile.name}"
      )
    end
  end

  @doc """
  Change settings in the selected profile: each is set live and read back
  (refused: wiring, or what the controller didn't apply), stored, then the
  controller's file is rewritten once. Only while the controller runs the
  app's file (not a file of your own).
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
          profile =
            revise(profile, Map.merge(profile.values, applied), "Changed on the controller")

          update(db, controller.id, profile.id, fn _ -> profile end)

          write(
            machine,
            db,
            controller,
            profile,
            "Changed #{count(applied)} in profile #{profile.name}"
          )
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
        do: update(db, id, pid, &revise(&1, Map.merge(&1.values, applied), "Edited"))

      {:ok, %{applied: applied, errors: errors}}
    end
  end

  @doc """
  Put a profile back to one of its earlier revisions: a new revision
  ("Restored ..."), with its diff. The selected profile is then written to
  the controller, which restarts.
  """
  @spec restore(GenServer.server(), GenServer.server(), map, String.t(), non_neg_integer) ::
          :ok | {:error, term}
  def restore(machine, db, controller, pid, index) do
    with %{} = profile <- find(db, controller.id, pid) || {:error, :not_found},
         %{values: values, version: v} <-
           Enum.at(profile.history, index) || {:error, :not_found} do
      update(db, controller.id, pid, &revise(&1, values, "Restored v#{v}"))

      if stored(db, controller.id).selected == pid,
        do:
          switch(
            machine,
            db,
            controller,
            pid,
            "Restored profile #{profile.name} to its v#{v}"
          ),
        else: :ok
    end
  end

  @doc "What restoring a profile's revision would change: `[%{path, from, to}]`."
  def restore_diff(db, id, pid, index) do
    with %{} = profile <- find(db, id, pid),
         %{values: values} <- Enum.at(profile.history, index) do
      diff_maps(profile.values, values)
    else
      _ -> []
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
      profile = revise(profile, values, "Kept running values")
      update(db, controller.id, profile.id, fn _ -> profile end)

      reason = "Kept #{count(list)} running in profile #{profile.name}"
      with {:ok, _} <- write(machine, db, controller, profile, reason), do: :ok
    end
  end

  @doc "Put the selected profile's values back on the controller (live; recorded)."
  def put_back(machine, db, id) do
    with {:ok, list} <- drift(machine, db, id),
         %{} = profile <- selected(db, id) do
      Enum.each(list, &Config.set(machine, &1.path, &1.profile))

      if list != [] do
        Config.record(db, id, %{
          reason: "Put back #{count(list)} of profile #{profile.name} (live, file unchanged)",
          diff: for(d <- list, do: %{path: d.path, from: d.controller, to: d.profile})
        })
      end

      :ok
    end
  end

  @doc """
  An override: a config file of your own replaces the controller's and the
  controller restarts with it; recorded with `reason` ("Uploaded mine.yaml",
  "Pasted a config"). `check/3` then shows how it differs from the profile.
  """
  @spec replace_file(GenServer.server(), GenServer.server(), map, String.t(), String.t()) ::
          :ok | {:error, term}
  def replace_file(machine, db, controller, text, reason) do
    with true <- Config.parse(text) != [] || {:error, :not_a_config},
         {:ok, _} <- Config.upload(machine, @config_file, text, {db, controller.id, reason}) do
      Config.activate(machine, @config_file)
    end
  end

  @doc """
  How two profiles differ, as each would be written for a board:
  `[%{path, from, to}]` (`from` is profile `a`, `to` is `b`; `nil` where
  one has no value).
  """
  @spec diff(atom, profile, profile) :: [
          %{path: String.t(), from: String.t() | nil, to: String.t() | nil}
        ]
  def diff(_board, a, b), do: diff_maps(a.values, b.values)

  @doc """
  The file a profile makes for a board: the board's wiring (and its name
  and the machine's), then exactly the profile's values. Nothing else from
  the board's default config: a setting the profile doesn't have is left
  out, and FluidNC uses its own default for it.
  """
  @spec render(atom, profile) :: String.t()
  def render(board, profile) do
    wiring =
      board
      |> Boards.config()
      |> Yaml.parse()
      |> Yaml.filter(&(not editable?(&1)))

    tree =
      profile.values
      |> Enum.sort()
      |> Enum.reduce(wiring, fn {path, v}, tree -> Yaml.put(tree, path, v) end)

    """
    # Written by the CNC app: board #{Boards.label(board)}, profile "#{profile.name}".
    # Change it from the app (Controllers > Configuration); edits here show
    # there as differences from the profile.

    """ <> Yaml.render(tree)
  end

  ## Revisions

  defp new_profile(name, values, reason) do
    %{id: new_id(), name: name, values: %{}, history: []}
    |> revise(values, reason)
  end

  # New values with a revision: why, what changed, and the values after.
  defp revise(profile, values, reason) do
    entry = %{
      version: next_version(profile.history),
      at: DateTime.utc_now(:second),
      reason: reason,
      diff: diff_maps(profile.values, values),
      values: values
    }

    %{profile | values: values, history: Enum.take([entry | profile.history], @history_max)}
  end

  defp next_version([%{version: v} | _]), do: v + 1
  defp next_version(history), do: length(history) + 1

  # (A tuple, not two bindings: in a comprehension a binding to nil filters
  # the element out, and a value missing on one side counts.)
  defp diff_maps(from, to) do
    for path <- Enum.sort(Enum.uniq(Map.keys(from) ++ Map.keys(to))),
        {x, y} = {from[path], to[path]},
        x == nil or y == nil or not Config.same?(x, y),
        do: %{path: path, from: x, to: y}
  end

  defp count(map_or_list) do
    case Enum.count(map_or_list) do
      1 -> "1 setting"
      n -> "#{n} settings"
    end
  end

  ## Storage

  defp write(machine, db, controller, profile, reason),
    do:
      Config.upload(
        machine,
        @config_file,
        render(controller.board, profile),
        {db, controller.id, reason}
      )

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

  # Profiles stored before carry other keys (a :file) and no history.
  defp stored(db, id) do
    s = Map.merge(%{profiles: [], selected: nil, seen: nil}, CubDB.get(db, {@key, id}, %{}))

    profiles =
      for p <- s.profiles,
          do: Map.merge(%{history: []}, Map.take(p, [:id, :name, :values, :history]))

    %{s | profiles: profiles}
  end

  defp put(db, id, data), do: CubDB.put(db, {@key, id}, data)

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
end
