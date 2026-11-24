defmodule CNC.Transport.Sim do
  @moduledoc """
  In-process fake controller implementing the `CNC.Transport` port.

  A thin GenServer around `CNC.Transport.Sim.Model` (the pure core). The process
  owns only the side effects: a 10 ms tick while the model is busy, delivery
  of reply lines to the owner, and fault-injection hooks for tests.

  Options (plus the model's, see `CNC.Transport.Sim.Model.new/1`):
    * `:latency` — ms delay before each reply line reaches the owner (default 0)
    * `:drop_acks` — swallow `ok` replies (default false)
    * `:name` — process registration
  """
  @behaviour CNC.Transport
  use GenServer

  alias CNC.Transport.Sim.Model

  @tick_ms 10

  @impl CNC.Transport
  def start_link(owner, opts \\ []),
    do: GenServer.start_link(__MODULE__, {owner, opts}, Keyword.take(opts, [:name]))

  @impl CNC.Transport
  def write_line(pid, line), do: GenServer.cast(pid, {:line, IO.iodata_to_binary(line)})

  @impl CNC.Transport
  def write_realtime(pid, byte), do: GenServer.cast(pid, {:realtime, byte})

  @impl CNC.Transport
  def close(pid), do: GenServer.cast(pid, :close)

  ## Test hooks

  @doc "Change `:latency` / `:drop_acks` at runtime."
  def configure(pid, opts), do: GenServer.call(pid, {:configure, opts})

  @doc "Raise `ALARM:code` as the controller would (e.g. a limit switch)."
  def inject_alarm(pid, code), do: GenServer.call(pid, {:alarm, code})

  @doc "Simulate transport loss: owner gets `{:transport, :disconnected}`, process exits."
  def disconnect(pid), do: GenServer.call(pid, :disconnect)

  @doc "The current model, for assertions."
  def model(pid), do: GenServer.call(pid, :model)

  ## Server

  defstruct [:owner, :model, :tick_at, latency: 0, drop_acks: false, outbox: :queue.new()]

  @impl GenServer
  def init({owner, opts}) do
    s = %__MODULE__{
      owner: owner,
      model: Model.new(opts),
      latency: Keyword.get(opts, :latency, 0),
      drop_acks: Keyword.get(opts, :drop_acks, false)
    }

    send(owner, {:transport, :connected})
    {model, lines} = Model.boot(s.model)
    {:ok, emit(%{s | model: model}, lines)}
  end

  @impl GenServer
  def handle_cast({:line, line}, s), do: {:noreply, step(s, &Model.line(&1, line))}
  def handle_cast({:realtime, byte}, s), do: {:noreply, step(s, &Model.realtime(&1, byte))}
  def handle_cast(:close, s), do: {:stop, {:shutdown, :closed}, s}

  @impl GenServer
  def handle_call({:configure, opts}, _from, s),
    do: {:reply, :ok, struct!(s, Keyword.take(opts, [:latency, :drop_acks]))}

  def handle_call({:alarm, code}, _from, s), do: {:reply, :ok, step(s, &Model.alarm(&1, code))}
  def handle_call(:model, _from, s), do: {:reply, s.model, s}

  def handle_call(:disconnect, _from, s) do
    send(s.owner, {:transport, :disconnected})
    {:stop, {:shutdown, :disconnected}, :ok, s}
  end

  @impl GenServer
  def handle_info(:tick, s) do
    now = now()
    s = step(%{s | tick_at: nil}, &Model.advance(&1, now - s.tick_at))
    {:noreply, s}
  end

  def handle_info(:flush, s), do: {:noreply, flush(s)}

  # Apply a model transition, deliver its replies, keep the clock running if busy.
  defp step(s, fun) do
    {model, lines} = fun.(s.model)
    s |> Map.put(:model, model) |> emit(lines) |> schedule_tick()
  end

  defp schedule_tick(%{tick_at: nil} = s) do
    if Model.busy?(s.model) do
      Process.send_after(self(), :tick, @tick_ms)
      %{s | tick_at: now()}
    else
      s
    end
  end

  defp schedule_tick(s), do: s

  ## Reply delivery (in order, optionally delayed)

  defp emit(s, lines) do
    lines = if s.drop_acks, do: Enum.reject(lines, &(&1 == "ok")), else: lines
    due = now() + s.latency
    was_empty = :queue.is_empty(s.outbox)
    outbox = Enum.reduce(lines, s.outbox, &:queue.in({due, &1}, &2))
    s = %{s | outbox: outbox}
    if was_empty, do: flush(s), else: s
  end

  defp flush(s) do
    now = now()

    case :queue.peek(s.outbox) do
      {:value, {due, line}} when due <= now ->
        send(s.owner, {:transport, :line, line})
        flush(%{s | outbox: :queue.drop(s.outbox)})

      {:value, {due, _}} ->
        Process.send_after(self(), :flush, due - now)
        s

      :empty ->
        s
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
