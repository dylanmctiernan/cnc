defmodule CNCApp.Settings do
  @moduledoc """
  The app's own settings: how it looks and behaves, as opposed to the
  machine's configuration (`CNC.Configuration`). One set for the app (it's
  one machine, one user), kept in the app's database and applied live:
  every open screen hears a change (`subscribe/1`).

  Each setting has a default and a type; unknown keys and wrong types are
  refused, so the stored map only ever holds what's listed here.

    * `:jog_trail` (boolean, default false) — while jogging, the 2D map
      draws the path the tool moves (a running job draws its own trace)
  """
  use Boundary, top_level?: true, deps: [], exports: []

  @defaults %{jog_trail: false}
  @types %{jog_trail: :boolean}
  @key :app_settings
  @pubsub CNC.PubSub

  @type t :: %{jog_trail: boolean}

  @doc "Every setting, defaults filled in."
  @spec all(GenServer.server()) :: t
  def all(db) do
    stored = CubDB.get(db, @key, %{})
    Map.merge(@defaults, Map.take(stored, Map.keys(@defaults)))
  end

  @doc "One setting."
  def get(db, key) when is_map_key(@defaults, key), do: Map.fetch!(all(db), key)

  @doc "Change one setting; every screen hears `{:app_settings, all}`."
  @spec put(GenServer.server(), atom, term) :: {:ok, t} | {:error, :unknown | :invalid}
  def put(db, key, value) do
    cond do
      not is_map_key(@types, key) ->
        {:error, :unknown}

      not valid?(@types[key], value) ->
        {:error, :invalid}

      true ->
        settings = Map.put(all(db), key, value)
        :ok = CubDB.put(db, @key, settings)
        Phoenix.PubSub.broadcast(@pubsub, topic(db), {:app_settings, settings})
        {:ok, settings}
    end
  end

  @doc "Hear changes: `{:app_settings, all}`."
  def subscribe(db), do: Phoenix.PubSub.subscribe(@pubsub, topic(db))

  @doc "The defaults."
  def defaults, do: @defaults

  defp valid?(:boolean, v), do: is_boolean(v)

  defp topic(db), do: "app_settings:#{inspect(db)}"
end
