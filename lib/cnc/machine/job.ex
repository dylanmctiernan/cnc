defmodule CNC.Machine.Job do
  @moduledoc """
  A G-code file being streamed to the controller (the machine server's
  `:running` state). Pure bookkeeping; the server does the sending.

  Streaming by character counting, as Grbl's own streaming script and UGS,
  CNCjs and gSender do: the controller has a 128-byte serial receive buffer,
  so lines go out while the bytes sent but not yet acked (each line plus its
  newline) fit in #{127} bytes. Every `ok` frees its line's bytes. The
  buffer stays full without ever overflowing, so the planner never starves.

  Lines are cleaned before sending: comments (`( )`, `;`) and spaces are
  dropped (Grbl ignores them) and blank lines skipped, so they cost nothing.
  A line longer than the controller accepts (#{79} characters) is refused
  before anything is sent.

  An `error:N` on a job line stops the stream (`halted?`): nothing more is
  sent; what the controller already has finishes or is aborted.

  Modes (`:mode`, fixed when the job starts):

    * `:run` — the file is cut
    * `:check` — the controller's check mode (`$C`): it reads and validates
      every line without moving. Errors don't stop the stream: they're
      collected (`errors`), since the point is to list every line the
      controller refuses.
    * `{:dry, mm}` — a dry run (air cut): the real motion with Z lifted by
      `mm` and the spindle left off. Done to the lines as they're sent, so
      nothing on the controller has to be restored afterwards: every Z in
      absolute positioning (G90) gets the lift (relative moves are already
      relative to it; machine-coordinate G53 lines are left alone), and
      spindle on (M3/M4) is dropped.

  For progress and time left: `recent`, the file line numbers of the last
  #{32} lines acked, newest first (the controller acks a line when it's
  planned, well before it runs: with the planner's waiting moves, these say
  which line is actually being cut), and the time spent paused (on hold,
  door open, or waiting for Next line in single block), which isn't
  time the job is taking.

  Single block (`single_block?`, switchable mid-job): one line per Cycle
  Start. The job holds a `credit` of lines it may send; with single block
  on, each Start grants one (the server only grants it once the controller
  has finished the last line and is at rest).
  """

  @rx_buffer 127
  @max_line 79

  @type line :: {line_no :: pos_integer, text :: String.t()}
  @type t :: %__MODULE__{
          name: String.t(),
          queue: :queue.queue(line),
          in_flight: :queue.queue({pos_integer, pos_integer, String.t()}),
          bytes: non_neg_integer,
          total: non_neg_integer,
          sent: non_neg_integer,
          acked: non_neg_integer,
          last_line: non_neg_integer,
          started_at: DateTime.t(),
          error: nil | {code :: term, line_no :: pos_integer, text :: String.t()},
          halted?: boolean,
          aborting?: boolean,
          mode: :run | :check | {:dry, number},
          errors: [{code :: term, line_no :: pos_integer, text :: String.t()}],
          single_block?: boolean,
          credit: non_neg_integer | :infinity,
          recent: [pos_integer],
          paused_ms: non_neg_integer,
          paused_since: integer | nil,
          start: {float, float, float} | nil
        }

  defstruct [
    :name,
    :started_at,
    queue: :queue.new(),
    in_flight: :queue.new(),
    bytes: 0,
    total: 0,
    sent: 0,
    acked: 0,
    last_line: 0,
    error: nil,
    halted?: false,
    aborting?: false,
    # check mode: $C off has been sent
    exiting?: false,
    mode: :run,
    errors: [],
    single_block?: false,
    credit: :infinity,
    recent: [],
    paused_ms: 0,
    paused_since: nil,
    # Where the tool was (work coordinates) at Start: the file's first moves
    # go from here, so their time can only be known now
    start: nil
  ]

  @recent 32

  @doc """
  A job from a file's text. `{:error, :empty}` if nothing would be sent,
  `{:error, {:line_too_long, line_no}}` for a line the controller can't take.

      iex> {:ok, job} = CNC.Machine.Job.new("a.nc", "(hi)\\nG0 X1 ; go\\n\\nG1 Y2 F100\\n")
      iex> job.total
      2
  """
  @spec new(String.t(), binary, keyword) :: {:ok, t} | {:error, term}
  def new(name, text, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    mode = Keyword.get(opts, :mode, :run)
    single_block? = Keyword.get(opts, :single_block?, false)

    lines =
      text
      |> String.split(["\r\n", "\n", "\r"])
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {raw, n} ->
        case clean(raw) do
          "" -> []
          line -> [{n, line}]
        end
      end)
      |> dry(mode)

    cond do
      lines == [] ->
        {:error, :empty}

      long = Enum.find(lines, fn {_, l} -> byte_size(l) > @max_line end) ->
        {:error, {:line_too_long, elem(long, 0)}}

      true ->
        {:ok,
         %__MODULE__{
           name: name,
           queue: :queue.from_list(lines),
           total: length(lines),
           started_at: now,
           mode: mode,
           single_block?: single_block?,
           credit: if(single_block?, do: 1, else: :infinity),
           start: Keyword.get(opts, :start)
         }}
    end
  end

  # A dry run: Z words in absolute positioning lifted, spindle on dropped.
  # Lines left empty (a lone M3) are skipped.
  defp dry(lines, {:dry, lift}) do
    {lines, _absolute?} =
      Enum.flat_map_reduce(lines, true, fn {n, line}, absolute? ->
        absolute? =
          cond do
            Regex.match?(~r/G91(?![.\d])/i, line) -> false
            Regex.match?(~r/G90(?![.\d])/i, line) -> true
            true -> absolute?
          end

        line = Regex.replace(~r/M0*[34](?!\d)/i, line, "")

        line =
          if absolute? and not Regex.match?(~r/G53(?!\d)/i, line),
            do: lift_z(line, lift),
            else: line

        {if(line == "", do: [], else: [{n, line}]), absolute?}
      end)

    lines
  end

  defp dry(lines, _mode), do: lines

  defp lift_z(line, lift) do
    Regex.replace(~r/Z([-+]?\d*\.?\d+)/i, line, fn _, v ->
      {z, _} =
        Float.parse(
          if String.starts_with?(v, "."), do: "0" <> v, else: String.replace(v, "-.", "-0.")
        )

      "Z" <> :erlang.float_to_binary(z + lift, decimals: 3)
    end)
  end

  @doc "A line as sent: no comments, no spaces, no `%`."
  def clean(raw) do
    raw
    |> String.replace(~r/\(.*?\)|;.*$/, "")
    |> String.replace(~r/\s+/, "")
    |> case do
      "%" -> ""
      line -> line
    end
  end

  @doc "The next line to send, if it fits in the controller's buffer now."
  @spec next(t) :: {:send, line, t} | :wait
  def next(%__MODULE__{halted?: true}), do: :wait
  def next(%__MODULE__{credit: 0}), do: :wait

  def next(%__MODULE__{} = job) do
    case :queue.peek(job.queue) do
      {:value, {n, text} = line} ->
        size = byte_size(text) + 1

        if job.bytes + size <= @rx_buffer do
          {:send, line,
           %{
             job
             | queue: :queue.drop(job.queue),
               in_flight: :queue.in({n, size, text}, job.in_flight),
               bytes: job.bytes + size,
               sent: job.sent + 1,
               credit: if(job.credit == :infinity, do: :infinity, else: job.credit - 1)
           }}
        else
          :wait
        end

      :empty ->
        :wait
    end
  end

  @doc "The controller answered the oldest line in flight."
  @spec ack(t, :ok | {:error, term}) :: t
  def ack(%__MODULE__{} = job, result) do
    {{:value, {n, size, text}}, in_flight} = :queue.out(job.in_flight)

    job = %{
      job
      | in_flight: in_flight,
        bytes: job.bytes - size,
        acked: job.acked + 1,
        last_line: n,
        recent: Enum.take([n | job.recent], @recent)
    }

    case {result, job.mode} do
      {:ok, _} -> job
      {{:error, code}, :check} -> %{job | errors: job.errors ++ [{code, n, text}]}
      {{:error, code}, :run} -> %{job | error: job.error || {code, n, text}, halted?: true}
    end
  end

  # The oldest line sent and not yet acked: the one the controller is
  # taking in (an arc's first moves can be in its planner already)
  defp feeding(job) do
    case :queue.peek(job.in_flight) do
      {:value, {n, _, _}} -> n
      :empty -> nil
    end
  end

  @doc """
  Whether the job is paused now (`now` in monotonic ms): pauses are
  summed, so the time the job is taking can leave them out.
  """
  @spec pause(t, boolean, integer) :: t
  def pause(%__MODULE__{paused_since: nil} = job, true, now), do: %{job | paused_since: now}

  def pause(%__MODULE__{paused_since: since} = job, false, now) when since != nil,
    do: %{job | paused_ms: job.paused_ms + (now - since), paused_since: nil}

  def pause(job, _paused?, _now), do: job

  @doc "Milliseconds paused so far, counting a pause still going on."
  def paused_ms(%__MODULE__{paused_since: nil, paused_ms: ms}, _now), do: ms
  def paused_ms(%__MODULE__{paused_since: since, paused_ms: ms}, now), do: ms + (now - since)

  @doc "Single block: may the next line go? (one more)"
  def grant(%__MODULE__{single_block?: true} = job), do: %{job | credit: 1}
  def grant(job), do: job

  @doc "Single block on or off mid-job (off: the rest streams straight away)."
  def single_block(job, true), do: %{job | single_block?: true, credit: 0}
  def single_block(job, false), do: %{job | single_block?: false, credit: :infinity}

  @doc "Single block, the last line done, waiting for Start (needs the controller at rest)."
  def waiting?(%__MODULE__{} = job),
    do:
      job.single_block? and job.credit == 0 and :queue.is_empty(job.in_flight) and
        not :queue.is_empty(job.queue) and not job.halted?

  @doc "The next line to send, if any: {line_no, text}."
  def peek(%__MODULE__{queue: q}) do
    case :queue.peek(q) do
      {:value, line} -> line
      :empty -> nil
    end
  end

  @doc "Everything sent has been acked, and there's nothing more to send."
  def drained?(%__MODULE__{} = job),
    do: :queue.is_empty(job.in_flight) and (job.halted? or :queue.is_empty(job.queue))

  @doc "For the snapshot: what's running and how far it's got."
  def summary(nil), do: nil

  def summary(%__MODULE__{} = job) do
    %{
      name: job.name,
      total: job.total,
      sent: job.sent,
      acked: job.acked,
      line: job.last_line,
      started_at: job.started_at,
      error: job.error,
      halted?: job.halted?,
      mode: job.mode,
      errors: job.errors,
      single_block?: job.single_block?,
      next: peek(job),
      recent: job.recent,
      feeding: feeding(job),
      start: job.start
    }
  end
end
