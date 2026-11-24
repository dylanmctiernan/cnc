defmodule CNC.Link.FakeSim.Model do
  @moduledoc """
  Pure model of a small Grbl-ish controller: the functional core of
  `CNC.Link.FakeSim`. Every function returns `{model, lines}`, where `lines`
  are the controller's replies (no newlines). Time only moves via
  `advance/2`, so tests are deterministic.

  Deliberately not a faithful firmware: constant velocity (no acceleration),
  jog-only motion, relative metric jogs only (`$J=G91 G21 ...`).

  Fidelity notes (Grbl 1.1 behaviour it does mirror):
    * boots into `Alarm`; `$X`/`$H` allowed from `Alarm` or `Idle`, else `error:8`
    * `$J=` only from `Idle`/`Jog` (`error:8`); target outside travel → `error:15`
    * feed hold (`!`) during a jog cancels it, like jog cancel (`0x85`)
    * `$H` acks `ok` only when the cycle completes
    * soft reset while moving → `ALARM:3` (jog) / `ALARM:6` (homing)
    * `$$` lists max travel `$130`–`$132`; `$13x=<mm>` sets it (Idle/Alarm only)
    * `G10 L2 P1 X.. Y.. Z..` puts the G54 work zero at machine coordinates;
    * `G10 L20 P1 X.. Y.. Z..` sets the G54 work offset so the current position
      reads as the given values; `WCO` is reported every 10th status and in
      the first status after a change

  FluidNC config files (enough to test config work without a board): a
  local filesystem of `.yaml` files, `$Config/Filename` (which one loads at
  boot; not checked, like FluidNC), `$LocalFS/List|Show|Delete`, `$CD`
  (the running config), `$CD=<file>` (save it as a file), `$Bye`
  (restart: the chosen file becomes the running config) and `$/path` /
  `$/path=value` on the running config. It takes travel and max rate from
  its config (at power-up, on restart, and when set live). Like FluidNC, a bad number or the
  stepping engine answer `ok` without changing anything, and an unknown
  path is `error:3` followed by a message.

  Travel convention: X/Y run `0..length`, Z runs `-length..0` (origin
  front-left, Z zero at the top after homing).
  """

  alias CNC.Grbl.{Realtime, Status}

  @banner "Grbl 1.1h ['$' for help]"
  @locked "[MSG:'$H'|'$X' to unlock]"
  @planner_blocks 15
  @config """
  board: Fake sim
  name: Fake sim
  stepping:
    engine: Timed
  axes:
    X:
      steps_per_mm: 80.000
      max_rate_mm_per_min: 3000.000
      acceleration_mm_per_sec2: 500.000
      max_travel_mm: 1250.000
    Y:
      steps_per_mm: 80.000
      max_rate_mm_per_min: 3000.000
      acceleration_mm_per_sec2: 500.000
      max_travel_mm: 1250.000
    Z:
      steps_per_mm: 400.000
      max_rate_mm_per_min: 1000.000
      acceleration_mm_per_sec2: 200.000
      max_travel_mm: 100.000
  """

  @type xyz :: {float, float, float}
  @type t :: %__MODULE__{
          state: :alarm | :idle | :jog | :home,
          pos: xyz,
          queue: :queue.queue({xyz, float}),
          feed: float,
          travel: {{float, float}, {float, float}, {float, float}},
          max_feed: float,
          homing_ms: non_neg_integer,
          homing_left: number,
          wco: xyz,
          wco_in: non_neg_integer
        }

  defstruct state: :alarm,
            pos: {0.0, 0.0, 0.0},
            queue: :queue.new(),
            feed: 0.0,
            travel: {{0.0, 1250.0}, {0.0, 1250.0}, {-100.0, 0.0}},
            max_feed: 3000.0,
            homing_ms: 1000,
            homing_left: 0,
            wco: {0.0, 0.0, 0.0},
            wco_in: 0,
            files: %{"config.yaml" => @config},
            config_file: "config.yaml",
            running: @config

  @doc """
  Options: `:travel`, `:max_feed` (mm/min), `:homing_ms`, `:pos`, and the
  config: `:config` (the text of `config.yaml`), or `:files` (name => text)
  with `:config_file` (the one loaded at power-up, default `config.yaml`).
  Given a config, the fake sim takes its travel and max rate from it.
  """
  def new(opts \\ []) do
    m = struct!(__MODULE__, Keyword.take(opts, [:travel, :max_feed, :homing_ms, :pos]))

    case {Keyword.get(opts, :files), Keyword.get(opts, :config)} do
      {nil, nil} ->
        m

      {nil, text} ->
        take(%{m | files: %{"config.yaml" => text}, running: text})

      {files, _} ->
        file = Keyword.get(opts, :config_file, "config.yaml")
        take(%{m | files: files, config_file: file, running: Map.get(files, file, "")})
    end
  end

  # What the fake sim takes from its running config: each axis's travel
  # (X/Y 0..mm, Z -mm..0) and max rate (the fastest is its feed limit).
  defp take(m) do
    travel =
      ~w(x y z)
      |> Enum.with_index()
      |> Enum.reduce(m.travel, fn {axis, i}, travel ->
        case number(m.running, "axes/#{axis}/max_travel_mm") do
          mm when is_float(mm) and mm > 0 -> put_travel(travel, i, mm)
          _ -> travel
        end
      end)

    rates =
      for a <- ~w(x y z),
          r = number(m.running, "axes/#{a}/max_rate_mm_per_min"),
          is_float(r) and r > 0,
          do: r

    %{m | travel: travel, max_feed: if(rates == [], do: m.max_feed, else: Enum.max(rates))}
  end

  defp number(text, path) do
    with {:ok, v} <- setting(text, path), {n, _} <- Float.parse(v), do: n * 1.0, else: (_ -> nil)
  end

  @doc "Lines a controller prints on power-up."
  def boot(m), do: {m, [@banner, @locked]}

  @doc "True while time matters (motion or homing in progress)."
  def busy?(%__MODULE__{state: s}), do: s in [:jog, :home]

  ## Line commands

  def line(%{state: s} = m, "$X") when s in [:alarm, :idle] do
    msg = if s == :alarm, do: ["[MSG:Caution: Unlocked]"], else: []
    {%{m | state: :idle}, msg ++ ["ok"]}
  end

  def line(%{state: s} = m, "$H") when s in [:alarm, :idle],
    do: {%{m | state: :home, homing_left: m.homing_ms}, []}

  def line(m, "$" <> cmd) when cmd in ["X", "H"], do: {m, ["error:8"]}

  def line(m, "$I"),
    do: {m, ["[VER:1.1h.cnc-sim:]", "[FIRMWARE:CNC FakeSim]", "[DRIVER:Simulator]", "ok"]}

  def line(m, "$"), do: {m, ["[HLP:$$ $X $H $J=line $130=mm $131=mm $132=mm ~ ! ? ctrl-x]", "ok"]}

  def line(%{state: s} = m, "$$") when s in [:alarm, :idle], do: {m, settings(m) ++ ["ok"]}
  def line(m, "$$"), do: {m, ["error:8"]}

  def line(%{state: s} = m, "$13" <> <<axis, "=", value::binary>>)
      when s in [:alarm, :idle] and axis in ?0..?2 do
    case Float.parse(value) do
      {mm, ""} when mm > 0 -> {%{m | travel: put_travel(m.travel, axis - ?0, mm)}, ["ok"]}
      {_, ""} -> {m, ["error:4"]}
      _ -> {m, ["error:2"]}
    end
  end

  def line(%{state: s} = m, "$J=" <> words) when s in [:idle, :jog] do
    with {:ok, delta, feed} <- parse_jog(words),
         target = add(tail(m), delta),
         :ok <- within_travel(target, m.travel) do
      queue = :queue.in({target, min(feed, m.max_feed)}, m.queue)
      {%{m | state: :jog, queue: queue}, ["ok"]}
    else
      {:error, code} -> {m, ["error:#{code}"]}
    end
  end

  def line(m, "$J=" <> _), do: {m, ["error:8"]}

  ## FluidNC config files

  def line(m, "$LocalFS/List") do
    files = for {name, text} <- Enum.sort(m.files), do: "[FILE: #{name}|SIZE:#{byte_size(text)}]"
    {m, files ++ ["[localfs Free:1.00 MB Used:0.01 MB Total:1.01 MB]", "ok"]}
  end

  def line(m, "$LocalFS/Show=" <> name) do
    case Map.fetch(m.files, name) do
      {:ok, text} -> {m, text_lines(text) ++ ["ok"]}
      :error -> {m, ["[MSG:ERR: File operation failed]", "error:66"]}
    end
  end

  def line(m, "$LocalFS/Delete=" <> name),
    do: {%{m | files: Map.delete(m.files, name)}, ["[MSG:Files changed]", "ok"]}

  def line(m, "$Config/Filename"), do: {m, ["$Config/Filename=#{m.config_file}", "ok"]}
  def line(m, "$Config/Filename=" <> name), do: {%{m | config_file: name}, ["ok"]}
  def line(m, "$CD"), do: {m, text_lines(m.running) ++ ["ok"]}
  def line(m, "$CD=" <> name), do: {%{m | files: Map.put(m.files, name, m.running)}, ["ok"]}

  def line(m, "$/" <> rest) do
    case String.split(rest, "=", parts: 2) do
      [path] ->
        case setting(m.running, path) do
          {:ok, value} -> {m, ["$/#{path}=#{value}", "ok"]}
          :error -> {m, ["error:3", "[MSG:ERR: Invalid $ statement]"]}
        end

      [path, value] ->
        cond do
          setting(m.running, path) == :error ->
            {m, ["error:3", "[MSG:ERR: Invalid $ statement]"]}

          String.downcase(path) == "stepping/engine" ->
            {m, ["Runtime setting of step_engine objects is not supported", "ok"]}

          numeric?(setting(m.running, path)) and not numeric?({:ok, value}) ->
            {m, ["[MSG:ERR: Bad numeric value]", "ok"]}

          true ->
            {take(%{m | running: put_setting(m.running, path, value)}), ["ok"]}
        end
    end
  end

  # Restart: boots the chosen file (nothing if it's missing), locked.
  def line(m, "$Bye") do
    running = Map.get(m.files, m.config_file, "")
    m = take(%{stop(m, :alarm) | running: running, wco: {0.0, 0.0, 0.0}})
    {m, ["[MSG:INFO: Restarting]", "ok", @banner, @locked]}
  end

  # G54 work offset: the current position becomes the given work position.
  def line(%{state: s} = m, "G10 L20 P1" <> words) when s in [:idle, :alarm] do
    case parse_axes(words) do
      {:ok, []} ->
        {m, ["error:26"]}

      {:ok, axes} ->
        wco =
          Enum.reduce(axes, m.wco, fn {i, value}, wco ->
            put_elem(wco, i, elem(m.pos, i) - value)
          end)

        {%{m | wco: wco, wco_in: 0}, ["ok"]}

      :error ->
        {m, ["error:2"]}
    end
  end

  # G10 L2: the work zero at absolute machine coordinates.
  def line(%{state: s} = m, "G10 L2 P1" <> words) when s in [:idle, :alarm] do
    case parse_axes(words) do
      {:ok, []} ->
        {m, ["error:26"]}

      {:ok, axes} ->
        wco = Enum.reduce(axes, m.wco, fn {i, value}, wco -> put_elem(wco, i, value) end)
        {%{m | wco: wco, wco_in: 0}, ["ok"]}

      :error ->
        {m, ["error:2"]}
    end
  end

  def line(m, "G10" <> _), do: {m, ["error:8"]}
  def line(m, _), do: {m, ["error:20"]}

  ## Real-time bytes

  def realtime(m, byte) do
    cond do
      byte == Realtime.status() -> status_report(m)
      byte in [Realtime.jog_cancel(), Realtime.feed_hold()] -> {cancel_jog(m), []}
      byte == Realtime.resume() -> {m, []}
      byte == Realtime.reset() -> reset(m)
      true -> {m, []}
    end
  end

  @doc "Raise an alarm (test hook): stops motion, enters `Alarm`."
  def alarm(m, code), do: {stop(m, :alarm), ["ALARM:#{code}"]}

  ## Time

  @doc "Advance the model by `dt` milliseconds."
  def advance(%{state: :home} = m, dt) do
    left = m.homing_left - dt

    if left > 0,
      do: {%{m | homing_left: left}, []},
      else: {%{m | state: :idle, homing_left: 0, pos: {0.0, 0.0, 0.0}}, ["ok"]}
  end

  def advance(%{state: :jog} = m, dt), do: {move(m, dt), []}
  def advance(m, _dt), do: {m, []}

  defp move(m, dt) do
    case :queue.peek(m.queue) do
      :empty ->
        stop(m, :idle)

      {:value, {target, feed}} ->
        mm_per_ms = feed / 60_000
        dist = distance(m.pos, target)
        step = mm_per_ms * dt

        if step >= dist do
          m = %{m | pos: target, queue: :queue.drop(m.queue), feed: feed}
          move(m, dt - dist / mm_per_ms)
        else
          %{m | pos: toward(m.pos, target, step / dist), feed: feed}
        end
    end
  end

  ## Helpers

  defp settings(%{travel: {{x0, x1}, {y0, y1}, {z0, z1}}}) do
    for {n, len} <- [{130, x1 - x0}, {131, y1 - y0}, {132, z1 - z0}],
        do: "$#{n}=#{:erlang.float_to_binary(len / 1, decimals: 3)}"
  end

  defp put_travel(travel, 2, mm), do: put_elem(travel, 2, {-mm, 0.0})
  defp put_travel(travel, axis, mm), do: put_elem(travel, axis, {0.0, mm})

  # Like Grbl, WCO is included only every 10th report (and right after a change).
  defp status_report(m) do
    planner_free = max(@planner_blocks - :queue.len(m.queue), 0)

    line =
      Status.encode(%Status{
        state: m.state,
        mpos: m.pos,
        feed: m.feed,
        spindle: 0.0,
        buffer: {planner_free, 128},
        wco: if(m.wco_in == 0, do: m.wco)
      })

    {%{m | wco_in: rem(m.wco_in + 9, 10)}, [line]}
  end

  defp parse_axes(words) do
    words
    |> String.split(" ", trim: true)
    |> Enum.reduce_while({:ok, []}, fn
      <<letter, value::binary>>, {:ok, acc} when letter in ~c"XYZ" ->
        case Float.parse(value) do
          {n, ""} -> {:cont, {:ok, [{letter - ?X, n} | acc]}}
          _ -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp cancel_jog(%{state: :jog} = m), do: stop(m, :idle)
  defp cancel_jog(m), do: m

  defp reset(m) do
    {m, alarm} =
      case m.state do
        :jog -> {stop(m, :alarm), ["ALARM:3"]}
        :home -> {stop(m, :alarm), ["ALARM:6"]}
        _ -> {m, []}
      end

    locked = if m.state == :alarm, do: [@locked], else: []
    {m, alarm ++ [@banner] ++ locked}
  end

  # Settings in the running config's text, by path (any case): the line
  # whose chain of parent keys matches.
  defp setting(text, path) do
    case find_setting(text, path) do
      {_index, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp put_setting(text, path, value) do
    {index, _} = find_setting(text, path)
    lines = String.split(text, "\n")
    [_, indent, key] = Regex.run(~r/^(\s*)([^:]+):/, Enum.at(lines, index))
    lines |> List.replace_at(index, "#{indent}#{key}: #{value}") |> Enum.join("\n")
  end

  defp find_setting(text, path) do
    want = path |> String.downcase() |> String.split("/")

    text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reduce_while([], fn {line, i}, stack ->
      case Regex.run(~r/^(\s*)([^:]+):\s?(.*)$/, line) do
        [_, indent, key, value] ->
          depth = String.length(indent)
          stack = Enum.drop_while(stack, fn {d, _} -> d >= depth end)
          keys = Enum.reverse([String.downcase(key) | for({_, k} <- stack, do: k)])

          cond do
            value != "" and keys == want -> {:halt, {i, value}}
            value == "" -> {:cont, [{depth, String.downcase(key)} | stack]}
            true -> {:cont, stack}
          end

        nil ->
          {:cont, stack}
      end
    end)
    |> case do
      {_, _} = found -> found
      _ -> nil
    end
  end

  defp numeric?({:ok, value}), do: match?({_, ""}, Float.parse(value))
  defp numeric?(_), do: false

  @doc "A file put onto the controller (an upload)."
  def put_file(m, name, data), do: %{m | files: Map.put(m.files, name, data)}

  defp text_lines(text), do: String.split(String.trim_trailing(text, "\n"), "\n")

  defp stop(m, state), do: %{m | state: state, queue: :queue.new(), feed: 0.0, homing_left: 0}

  defp tail(m) do
    case :queue.peek_r(m.queue) do
      {:value, {target, _}} -> target
      :empty -> m.pos
    end
  end

  # Accepts exactly what CNC.Grbl.Command.jog/2 emits. Error codes follow Grbl:
  # 2 bad number, 20 unsupported, 22 feed not set.
  defp parse_jog(words) do
    words
    |> String.split(" ", trim: true)
    |> Enum.reduce_while(%{modes: [], delta: {0.0, 0.0, 0.0}, feed: nil}, &jog_word/2)
    |> case do
      {:error, _} = err -> err
      %{modes: modes} when modes != ["G21", "G91"] -> {:error, 20}
      %{feed: nil} -> {:error, 22}
      %{delta: delta, feed: feed} -> {:ok, delta, feed}
    end
  end

  defp jog_word(mode, acc) when mode in ["G91", "G21"],
    do: {:cont, %{acc | modes: Enum.sort([mode | acc.modes])}}

  defp jog_word(<<letter, value::binary>>, acc) when letter in ~c"XYZF" do
    case Float.parse(value) do
      {n, ""} when letter == ?F -> {:cont, %{acc | feed: n}}
      {n, ""} -> {:cont, %{acc | delta: put_axis(acc.delta, letter, n)}}
      _ -> {:halt, {:error, 2}}
    end
  end

  defp jog_word(_, _acc), do: {:halt, {:error, 20}}

  defp put_axis(delta, ?X, n), do: put_elem(delta, 0, n)
  defp put_axis(delta, ?Y, n), do: put_elem(delta, 1, n)
  defp put_axis(delta, ?Z, n), do: put_elem(delta, 2, n)

  defp within_travel({x, y, z}, {{x0, x1}, {y0, y1}, {z0, z1}}) do
    if x >= x0 and x <= x1 and y >= y0 and y <= y1 and z >= z0 and z <= z1,
      do: :ok,
      else: {:error, 15}
  end

  defp add({a, b, c}, {x, y, z}), do: {a + x, b + y, c + z}

  defp distance({a, b, c}, {x, y, z}),
    do: :math.sqrt((x - a) ** 2 + (y - b) ** 2 + (z - c) ** 2)

  defp toward({a, b, c}, {x, y, z}, f), do: {a + (x - a) * f, b + (y - b) * f, c + (z - c) * f}
end
