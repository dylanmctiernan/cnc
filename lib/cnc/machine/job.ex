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
          aborting?: boolean
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
    aborting?: false
  ]

  @doc """
  A job from a file's text. `{:error, :empty}` if nothing would be sent,
  `{:error, {:line_too_long, line_no}}` for a line the controller can't take.

      iex> {:ok, job} = CNC.Machine.Job.new("a.nc", "(hi)\\nG0 X1 ; go\\n\\nG1 Y2 F100\\n")
      iex> job.total
      2
  """
  @spec new(String.t(), binary, DateTime.t()) :: {:ok, t} | {:error, term}
  def new(name, text, now \\ DateTime.utc_now()) do
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
           started_at: now
         }}
    end
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
               sent: job.sent + 1
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
        last_line: n
    }

    case result do
      :ok -> job
      {:error, code} -> %{job | error: job.error || {code, n, text}, halted?: true}
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
      halted?: job.halted?
    }
  end
end
