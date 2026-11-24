defmodule CNC.Machine.Console do
  @moduledoc """
  Raw controller traffic, for humans: every line and real-time byte sent
  (`:out`) and every line received (`:in`).

  Status polling (`?` and the `<...>` replies, 5–20 per second) is tagged
  `:poll`, broadcast live, but not kept in history, so the last
  #{200} entries are the interesting ones.
  """

  alias CNC.Grbl.Realtime

  @max 200

  @type entry :: %{
          id: pos_integer,
          at: {{integer, integer, integer}, non_neg_integer},
          dir: :in | :out,
          kind: :line | :realtime | :poll,
          text: binary
        }

  defstruct entries: :queue.new(), size: 0

  def new, do: %__MODULE__{}

  @doc "Build an entry, timestamped with local time-of-day `{{h, m, s}, ms}`."
  def entry(dir, kind, text) do
    now = System.os_time(:millisecond)
    {_date, time} = :calendar.system_time_to_local_time(now, :millisecond)

    %{
      id: System.unique_integer([:positive, :monotonic]),
      at: {time, rem(now, 1000)},
      dir: dir,
      kind: kind,
      text: String.trim_trailing(text)
    }
  end

  @doc "Keep an entry in history (polls are dropped)."
  def push(console, %{kind: :poll}), do: console

  def push(%{size: @max} = c, entry),
    do: %{c | entries: :queue.in(entry, :queue.drop(c.entries))}

  def push(c, entry), do: %{c | entries: :queue.in(entry, c.entries), size: c.size + 1}

  def to_list(c), do: :queue.to_list(c.entries)

  @doc "Human-readable name for a real-time byte."
  def describe(byte) do
    cond do
      byte == Realtime.status() -> "? status"
      byte == Realtime.feed_hold() -> "! feed hold"
      byte == Realtime.resume() -> "~ resume"
      byte == Realtime.reset() -> "0x18 soft reset"
      byte == Realtime.jog_cancel() -> "0x85 jog cancel"
      true -> "0x" <> Integer.to_string(byte, 16)
    end
  end
end
