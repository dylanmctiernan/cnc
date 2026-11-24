defmodule CNC.Grbl.Status do
  @moduledoc """
  A status report: `<State|MPos:x,y,z|FS:f,s|...>`.

  The controller reports either `MPos` or `WPos` (per `$10`); the other is
  derived when the work coordinate offset (`WCO`) is known. `WCO` is only
  sent periodically, so it's often `nil`. Unknown fields are ignored, and
  axes beyond the first three are dropped.
  """

  @type xyz :: {float, float, float}
  @type state ::
          :idle
          | :run
          | :hold
          | :jog
          | :alarm
          | :door
          | :check
          | :home
          | :sleep
          | :tool
          | :unknown

  @type t :: %__MODULE__{
          state: state,
          substate: non_neg_integer | nil,
          mpos: xyz | nil,
          wpos: xyz | nil,
          wco: xyz | nil,
          feed: float | nil,
          spindle: float | nil,
          buffer: {planner_free :: non_neg_integer, rx_free :: non_neg_integer} | nil
        }

  defstruct state: :unknown,
            substate: nil,
            mpos: nil,
            wpos: nil,
            wco: nil,
            feed: nil,
            spindle: nil,
            buffer: nil

  @states %{
    "Idle" => :idle,
    "Run" => :run,
    "Hold" => :hold,
    "Jog" => :jog,
    "Alarm" => :alarm,
    "Door" => :door,
    "Check" => :check,
    "Home" => :home,
    "Sleep" => :sleep,
    "Tool" => :tool
  }
  @names Map.new(@states, fn {k, v} -> {v, k} end)

  @doc """
  Parse the inside of a `<...>` report. Returns `:error` if the report is
  malformed.
  """
  @spec parse(binary) :: {:ok, t} | :error
  def parse(body) do
    [state | fields] = String.split(body, "|")

    with {:ok, status} <- parse_state(state),
         {:ok, status} <- parse_fields(fields, status) do
      {:ok, derive(status)}
    end
  end

  @doc """
  Encode as a full report line (with `<>`, no newline). Positions get 3
  decimals; feed and spindle get none. Reports `MPos`, plus `WCO` and `Bf`
  when present. Used by `CNC.Transport.Sim`.
  """
  @spec encode(t) :: binary
  def encode(%__MODULE__{} = s) do
    state = Map.fetch!(@names, s.state) <> if(s.substate, do: ":#{s.substate}", else: "")

    fields =
      [
        state,
        "MPos:" <> xyz(s.mpos || {0, 0, 0}),
        "FS:#{num(s.feed || 0, 0)},#{num(s.spindle || 0, 0)}",
        s.wco && "WCO:" <> xyz(s.wco),
        s.buffer && "Bf:#{elem(s.buffer, 0)},#{elem(s.buffer, 1)}"
      ]
      |> Enum.reject(&is_nil/1)

    "<" <> Enum.join(fields, "|") <> ">"
  end

  defp parse_state(""), do: :error

  defp parse_state(state) do
    {name, sub} =
      case String.split(state, ":", parts: 2) do
        [name] -> {name, nil}
        [name, sub] -> {name, sub}
      end

    with {:ok, substate} <- substate(sub) do
      {:ok, %__MODULE__{state: Map.get(@states, name, :unknown), substate: substate}}
    end
  end

  defp substate(nil), do: {:ok, nil}

  defp substate(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_fields([], status), do: {:ok, status}

  defp parse_fields([field | rest], status) do
    with {:ok, status} <- parse_field(String.split(field, ":", parts: 2), status) do
      parse_fields(rest, status)
    end
  end

  defp parse_field(["MPos", v], s), do: put_xyz(s, :mpos, v)
  defp parse_field(["WPos", v], s), do: put_xyz(s, :wpos, v)
  defp parse_field(["WCO", v], s), do: put_xyz(s, :wco, v)

  defp parse_field(["FS", v], s) do
    with {:ok, [f, sp]} <- floats(v, 2), do: {:ok, %{s | feed: f, spindle: sp}}
  end

  defp parse_field(["F", v], s) do
    with {:ok, [f]} <- floats(v, 1), do: {:ok, %{s | feed: f}}
  end

  defp parse_field(["Bf", v], s) do
    case String.split(v, ",") |> Enum.map(&Integer.parse/1) do
      [{p, ""}, {r, ""}] -> {:ok, %{s | buffer: {p, r}}}
      _ -> :error
    end
  end

  defp parse_field(_unknown, s), do: {:ok, s}

  defp put_xyz(s, key, v) do
    case floats(v, :any) do
      {:ok, [x, y, z | _]} -> {:ok, Map.put(s, key, {x, y, z})}
      _ -> :error
    end
  end

  defp floats(v, count) do
    parsed = v |> String.split(",") |> Enum.map(&Float.parse/1)

    if Enum.all?(parsed, &match?({_, ""}, &1)) and (count == :any or length(parsed) == count) do
      {:ok, Enum.map(parsed, &elem(&1, 0))}
    else
      :error
    end
  end

  defp derive(%{wco: nil} = s), do: s
  defp derive(%{mpos: {_, _, _} = m, wpos: nil, wco: o} = s), do: %{s | wpos: sub(m, o)}
  defp derive(%{wpos: {_, _, _} = w, mpos: nil, wco: o} = s), do: %{s | mpos: add(w, o)}
  defp derive(s), do: s

  defp sub({a, b, c}, {x, y, z}), do: {a - x, b - y, c - z}
  defp add({a, b, c}, {x, y, z}), do: {a + x, b + y, c + z}

  defp xyz({x, y, z}), do: Enum.map_join([x, y, z], ",", &num(&1, 3))

  defp num(n, decimals), do: :erlang.float_to_binary(n / 1, decimals: decimals)
end
