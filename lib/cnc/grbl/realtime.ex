defmodule CNC.Grbl.Realtime do
  @moduledoc """
  Single-byte real-time commands. Sent without a newline, never acked,
  acted on immediately by the controller (they bypass the line buffer).
  """

  @doc "Request a status report (`?`)."
  def status, do: ??

  @doc "Feed hold (`!`)."
  def feed_hold, do: ?!

  @doc "Cycle start / resume (`~`)."
  def resume, do: ?~

  @doc "Soft reset (Ctrl-X)."
  def reset, do: 0x18

  @doc "Cancel the active jog and flush queued jog lines."
  def jog_cancel, do: 0x85
end
