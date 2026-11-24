defmodule CNC.Configuration.Build do
  @moduledoc """
  The machine's build: how the router is put together, whichever controller
  drives it. Its drive train (`steps_per_mm`) and geometry (travel, homing
  direction and position, pulloff, hard limits). One for the machine, kept
  in the app with a version per change, seeded from what the first
  controller ran. It carries over when another controller takes over.

  Together with a controller's wiring (`CNC.Configuration.Wiring`) and the
  selected profile (`CNC.Configuration.Profiles`) it makes the controller's
  config file. `layer/1` says which of the three a value belongs to.
  """

  alias CNC.Boards
  alias CNC.Configuration.{Layer, Values}

  @key :build

  @physical ~r{^axes/[^/]+/(steps_per_mm|max_travel_mm|homing/(positive_direction|mpos_mm)|motor\d+/(pulloff_mm|hard_limits))$}

  @doc """
  Which layer a value belongs to: `:label` (the file's names), `:wiring`
  (the controller's), `:build` (the machine's) or `:profile` (how it's run).

      iex> CNC.Configuration.Build.layer("axes/x/steps_per_mm")
      :build
      iex> CNC.Configuration.Build.layer("axes/x/motor0/standard_stepper/step_pin")
      :wiring
      iex> CNC.Configuration.Build.layer("axes/x/max_rate_mm_per_min")
      :profile
      iex> CNC.Configuration.Build.layer("board")
      :label
  """
  @spec layer(String.t()) :: :label | :wiring | :build | :profile
  def layer(path) do
    cond do
      path in ~w(board name meta) -> :label
      Boards.wiring?(path) -> :wiring
      Regex.match?(@physical, path) -> :build
      true -> :profile
    end
  end

  @doc """
  The values of one layer in a config's text. Unconnected pins (`NO_PIN`)
  are left out: FluidNC lists every pin it has, and an unconnected one
  means the same as one not mentioned.
  """
  def pick(text, layer),
    do:
      for(
        {p, v} <- Values.parse(text),
        layer(p) == layer,
        not unconnected?(p, v),
        into: %{},
        do: {p, v}
      )

  @doc "An unconnected pin (`NO_PIN`), the same as not mentioning it."
  def unconnected?(path, value),
    do: String.ends_with?(path, "_pin") and String.upcase(String.trim(value)) == "NO_PIN"

  def values(db), do: Layer.values(db, @key)
  def history(db), do: Layer.history(db, @key)

  def ensure(db, running_text),
    do: Layer.ensure(db, @key, pick(running_text, :build), "Taken from what the controller ran")

  def change(db, changes, reason), do: Layer.change(db, @key, changes, reason)
  def replace(db, values, reason), do: Layer.replace(db, @key, values, reason)
  def restore(db, index), do: Layer.restore(db, @key, index)
end
