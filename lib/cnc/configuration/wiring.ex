defmodule CNC.Configuration.Wiring do
  @moduledoc """
  How a controller is wired to the machine: pins (with direction
  inversion), the stepping engine and buses. One per controller, kept in the
  app with a version per change, seeded from what the controller runs (its
  board's pin map, `CNC.Boards`, is where a fresh one starts). FluidNC only
  changes wiring from the file, so a change needs a restart.
  """

  alias CNC.Configuration.{Build, Layer}

  defp key(id), do: {:wiring, id}

  def values(db, id), do: Layer.values(db, key(id))
  def history(db, id), do: Layer.history(db, key(id))

  def ensure(db, id, running_text),
    do:
      Layer.ensure(
        db,
        key(id),
        Build.pick(running_text, :wiring),
        "Taken from what the controller ran"
      )

  def change(db, id, changes, reason), do: Layer.change(db, key(id), changes, reason)
  def replace(db, id, values, reason), do: Layer.replace(db, key(id), values, reason)
  def restore(db, id, index), do: Layer.restore(db, key(id), index)
  def forget(db, id), do: Layer.delete(db, key(id))
end
