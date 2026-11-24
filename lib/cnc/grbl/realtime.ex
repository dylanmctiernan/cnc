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

  @doc """
  Feed override: back to 100%, ±10%, ±1% (the controller keeps it within
  10–200%). Takes effect immediately, mid-move.
  """
  def feed_override(:reset), do: 0x90
  def feed_override(:plus10), do: 0x91
  def feed_override(:minus10), do: 0x92
  def feed_override(:plus1), do: 0x93
  def feed_override(:minus1), do: 0x94
end
