defmodule CNC.Configuration do
  @moduledoc """
  Configuration: everything about how the machine is built, wired and run,
  and keeping a controller's config file in step with it. (The app's own
  preferences are settings, not configuration.)

  Three parts, each with a version per change (its reason and diff):

    * the machine's **build** (`CNC.Configuration.Build`): steps/mm, travel,
      homing geometry; one for the machine;
    * each controller's **wiring** (`CNC.Configuration.Wiring`): pins,
      stepping engine, buses;
    * the machine's **profiles** (`CNC.Configuration.Profiles`): how it's
      run; one selected.

  A controller's config file, `config.yaml`, is exactly its wiring, the
  build and the selected profile (`render/3`); nothing is merged in from
  templates, so a value none of them has is left to FluidNC's default.
  This module coordinates changes to any of the three with the controller
  (through `CNC.Configuration.FluidNC`): switching profiles, changing values
  (build and profile values apply live, wiring after a restart), checking
  the file against them, keeping or putting back values the controller runs
  differently, overrides (a file of your own) and restores. Every write to
  a controller's config is in its history (`CNC.Configuration.History`).

  Controllers are passed in as maps with an `:id` and a `:board`.
  """
  use Boundary,
    deps: [CNC.Machine, CNC.Boards],
    exports: [Build, FluidNC, History, Profiles, Values, Wiring, Yaml]

  alias CNC.Boards
  alias CNC.Configuration.{Build, FluidNC, History, Profiles, Values, Wiring, Yaml}

  # The one file on a controller
  @config_file "config.yaml"

  @doc "The config file the app keeps on a controller."
  def file, do: @config_file

  @doc """
  First contact with a controller: its wiring from what it runs; and, for
  the machine's first controller, the build and a "Default" profile too.
  Nothing is written to the controller.
  """
  @spec ensure(GenServer.server(), GenServer.server(), map) :: :ok | {:error, term}
  def ensure(machine, db, controller) do
    with {:ok, running} <- FluidNC.running(machine) do
      Profiles.migrate(db, controller.id)
      Wiring.ensure(db, controller.id, running)
      Build.ensure(db, running)
      Profiles.ensure(db, Build.pick(running, :profile))
    end
  end

  @doc "What a controller's file should hold with a profile: its wiring, the build, the profile."
  def expected(db, controller, profile),
    do:
      Wiring.values(db, controller.id)
      |> Map.merge(Build.values(db))
      |> Map.merge(profile.values)

  @doc """
  The controller's file against what it should hold (wiring + build +
  selected profile): which file it loaded, whether it's the app's file
  holding exactly that, and the values that differ (`[%{path, layer,
  profile, controller}]`: what the configuration says and what the file
  says, `nil` where one has no value).
  """
  @spec check(GenServer.server(), GenServer.server(), map) :: {:ok, map} | {:error, term}
  def check(machine, db, controller) do
    with {:ok, %{active: loaded}} <- FluidNC.files(machine),
         %{} = profile <- Profiles.selected(db) || {:error, :no_profile},
         {:ok, text} <- FluidNC.show(machine, loaded || @config_file) do
      in_file =
        for {p, v} <- Values.parse(text),
            Build.layer(p) != :label,
            not Build.unconnected?(p, v),
            into: %{},
            do: {p, v}

      differences =
        for %{path: path, from: want, to: have} <-
              Values.diff_maps(expected(db, controller, profile), in_file),
            do: %{path: path, layer: Build.layer(path), profile: want, controller: have}

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
  What the last `check/3` found for a controller, for showing without
  asking it: `%{name: profile, matches?: boolean}`, or nil.
  """
  def last_seen(db, controller_id), do: CubDB.get(db, {:seen, controller_id})

  @doc """
  Switch to a profile (or write the selected one again): the controller's
  file becomes its wiring + the build + that profile, is chosen for boot,
  and the controller restarts with it (and comes back locked). Recorded in
  its history (`reason` defaults to "Switched to profile X" / "Wrote
  profile X").
  """
  @spec switch(GenServer.server(), GenServer.server(), map, String.t(), String.t() | nil) ::
          :ok | {:error, term}
  def switch(machine, db, controller, pid, reason \\ nil) do
    with %{} = profile <- Profiles.find(db, pid) || {:error, :not_found} do
      reason =
        reason ||
          if match?(%{id: ^pid}, Profiles.selected(db)),
            do: "Wrote profile #{profile.name}",
            else: "Switched to profile #{profile.name}"

      with {:ok, _} <- write(machine, db, controller, profile, reason) do
        Profiles.select(db, pid)
        FluidNC.activate(machine, @config_file)
      end
    end
  end

  @doc """
  Change values, each in its part: build and profile values are set live
  and read back (FluidNC may not apply one), wiring is checked here and
  takes effect on the restart that follows. Then the controller's file is
  written once. Only while it runs the app's file (not a file of your own).
  """
  @spec set(GenServer.server(), GenServer.server(), map, [{String.t(), String.t()}]) ::
          {:ok, %{applied: map, errors: map, restart?: boolean}} | {:error, term}
  def set(machine, db, controller, changes) do
    with {:ok, %{active: @config_file}} <- FluidNC.files(machine),
         %{} = profile <- Profiles.selected(db) || {:error, :no_profile} do
      current = expected(db, controller, profile)

      {applied, errors} =
        Enum.reduce(changes, {%{}, %{}}, fn {path, value}, {ok, bad} ->
          path = Profiles.clean(path)

          case apply_one(machine, path, value, current[path]) do
            {:ok, now} -> {Map.put(ok, path, now), bad}
            {:error, reason} -> {ok, Map.put(bad, path, reason)}
          end
        end)

      by_part = Enum.group_by(applied, fn {p, _} -> Build.layer(p) end)
      restart? = Map.has_key?(by_part, :wiring)

      written =
        if applied == %{} do
          :ok
        else
          why = "Changed on the controller"
          store(db, controller, profile, by_part, why)
          reason = "Changed #{count(applied)}#{parts_note(by_part, profile)}"

          with {:ok, _} <- write(machine, db, controller, Profiles.selected(db), reason),
               do: if(restart?, do: FluidNC.activate(machine, @config_file), else: :ok)
        end

      case written do
        {:error, reason} -> {:error, {:not_written, reason}}
        _ -> {:ok, %{applied: applied, errors: errors, restart?: restart?}}
      end
    else
      {:ok, %{active: _other}} -> {:error, :override}
      other -> other
    end
  end

  # Wiring isn't set live (FluidNC won't); the rest is, and read back.
  defp apply_one(machine, path, value, old) do
    case Build.layer(path) do
      :label -> {:error, :not_editable}
      :wiring -> Profiles.check_value(value, old)
      _ -> FluidNC.set(machine, path, value)
    end
  end

  # Values (grouped by part) into their parts, as new versions.
  defp store(db, controller, profile, by_part, why) do
    Wiring.change(db, controller.id, Map.new(by_part[:wiring] || []), why)
    Build.change(db, Map.new(by_part[:build] || []), why)
    Profiles.change(db, profile.id, Map.new(by_part[:profile] || []), why)
  end

  @doc """
  Keep what the controller runs (its file was changed elsewhere, a version
  restored, a file of your own, and that's the one to keep): its values,
  with FluidNC's defaults for whatever the file leaves out, go into the
  controller's wiring, the build and the selected profile; then the file is
  written from them and the controller restarts, so they agree.
  """
  def take_file(machine, db, controller) do
    with %{} = profile <- Profiles.selected(db) || {:error, :no_profile},
         {:ok, running} <- FluidNC.running(machine) do
      why = "Kept the controller's values"
      Wiring.replace(db, controller.id, Build.pick(running, :wiring), why)
      Build.replace(db, Build.pick(running, :build), why)
      Profiles.replace(db, profile.id, Build.pick(running, :profile), why)
      switch(machine, db, controller, profile.id, "#{why} (profile #{profile.name})")
    end
  end

  @doc """
  Live values that differ from the configuration (changed in the console,
  say): `[%{path, layer, profile, controller}]`.
  """
  @spec drift(GenServer.server(), GenServer.server(), map) :: {:ok, [map]} | {:error, term}
  def drift(machine, db, controller) do
    with %{} = profile <- Profiles.selected(db) || {:error, :no_profile},
         {:ok, running} <- FluidNC.running(machine) do
      now = Map.new(Values.parse(running))

      differences =
        for {path, want} <- Enum.sort(expected(db, controller, profile)),
            have = now[path],
            have != nil and not Values.same?(have, want),
            do: %{path: path, layer: Build.layer(path), profile: want, controller: have}

      {:ok, differences}
    end
  end

  @doc "Take the live values into their parts, and write the file."
  def keep_drift(machine, db, controller) do
    with {:ok, list} <- drift(machine, db, controller),
         %{} = profile <- Profiles.selected(db) do
      by_part = Enum.group_by(list, & &1.layer, &{&1.path, &1.controller})
      store(db, controller, profile, by_part, "Kept running values")
      reason = "Kept #{count(list)} running#{parts_note(by_part, profile)}"
      with {:ok, _} <- write(machine, db, controller, Profiles.selected(db), reason), do: :ok
    end
  end

  @doc "Put the configuration's values back on the controller (live; recorded)."
  def put_back(machine, db, controller) do
    with {:ok, list} <- drift(machine, db, controller) do
      Enum.each(list, &FluidNC.set(machine, &1.path, &1.profile))

      if list != [] do
        History.record(db, controller.id, %{
          reason: "Put back #{count(list)} (live, file unchanged)",
          diff: for(d <- list, do: %{path: d.path, from: d.controller, to: d.profile})
        })
      end

      :ok
    end
  end

  @doc """
  Put a profile back to one of its earlier versions: a new version
  ("Restored v3"), with its diff. The selected profile is then written to
  the controller, which restarts.
  """
  def restore_profile(machine, db, controller, pid, index) do
    with %{} = profile <- Profiles.find(db, pid) || {:error, :not_found},
         %{values: values, version: v} <-
           Enum.at(profile.history, index) || {:error, :not_found} do
      Profiles.replace(db, pid, values, "Restored v#{v}")

      if match?(%{id: ^pid}, Profiles.selected(db)),
        do: switch(machine, db, controller, pid, "Restored profile #{profile.name} to its v#{v}"),
        else: :ok
    end
  end

  @doc """
  Put an earlier version of the build or a controller's wiring back (a new
  version), then write the controller's file and restart.
  """
  def restore_part(machine, db, controller, part, index) do
    result =
      case part do
        :build -> Build.restore(db, index)
        :wiring -> Wiring.restore(db, controller.id, index)
      end

    with :ok <- result,
         %{} = profile <- Profiles.selected(db) || {:error, :no_profile} do
      switch(machine, db, controller, profile.id, "Restored the #{part} to an earlier version")
    end
  end

  @doc """
  An override: a config file of your own replaces the controller's and the
  controller restarts with it; recorded with `reason` ("Uploaded mine.yaml",
  "Pasted a config"). `check/3` then shows how it differs.
  """
  @spec replace_file(GenServer.server(), GenServer.server(), map, String.t(), String.t()) ::
          :ok | {:error, term}
  def replace_file(machine, db, controller, text, reason) do
    with true <- Values.parse(text) != [] || {:error, :not_a_config},
         {:ok, _} <- FluidNC.upload(machine, @config_file, text, {db, controller.id, reason}) do
      FluidNC.activate(machine, @config_file)
    end
  end

  @doc """
  The controller's wiring against its board's stock pin map
  (`CNC.Boards.config/1`), for information: how many wiring values were
  compared (only ones both have) and where they differ, `[%{path, board,
  controller}]`.
  """
  @spec wiring_check(atom, [{String.t(), String.t()}]) ::
          %{checked: non_neg_integer, differences: [map]}
  def wiring_check(board, running_values) do
    running = Map.new(running_values)

    compared =
      for {path, expected} <- Values.parse(Boards.config(board)),
          Boards.wiring?(path),
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
      do: Boards.normalize_pin(a) == Boards.normalize_pin(b),
      else: Values.same?(a, b)
  end

  @doc """
  A controller's file for a profile: the names, then exactly its wiring,
  the build and the profile's values, laid out as the board's config lays
  them out. Nothing merged in from templates.
  """
  @spec render(GenServer.server(), map, Profiles.profile()) :: String.t()
  def render(db, controller, profile) do
    values = expected(db, controller, profile)

    tree =
      controller.board
      |> Boards.config()
      |> Yaml.parse()
      |> Yaml.filter(&(Build.layer(&1) == :label or Map.has_key?(values, &1)))

    tree = values |> Enum.sort() |> Enum.reduce(tree, fn {p, v}, t -> Yaml.put(t, p, v) end)

    """
    # Written by the CNC app: board #{Boards.label(controller.board)}, profile "#{profile.name}".
    # Its wiring, the machine's build and the profile; change them from the
    # app (Controllers > Configuration). Edits here show there as differences.

    """ <> Yaml.render(tree)
  end

  @doc "Forget what's kept for a controller (it was removed)."
  def forget(db, controller_id) do
    History.forget(db, controller_id)
    Wiring.forget(db, controller_id)
    CubDB.delete(db, {:seen, controller_id})
  end

  defp write(machine, db, controller, profile, reason),
    do:
      FluidNC.upload(
        machine,
        @config_file,
        render(db, controller, profile),
        {db, controller.id, reason}
      )

  defp remember(db, id, seen) do
    if CubDB.get(db, {:seen, id}) != seen, do: CubDB.put(db, {:seen, id}, seen)
  end

  defp parts_note(by_part, profile) do
    parts =
      for {part, label} <- [
            build: "the build",
            wiring: "the wiring",
            profile: "profile #{profile.name}"
          ],
          Map.has_key?(by_part, part),
          do: label

    " (" <> Enum.join(parts, ", ") <> ")"
  end

  defp count(map_or_list) do
    case Enum.count(map_or_list) do
      1 -> "1 value"
      n -> "#{n} values"
    end
  end
end
