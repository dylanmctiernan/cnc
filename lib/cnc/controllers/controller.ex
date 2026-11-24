defmodule CNC.Controllers.Controller do
  @moduledoc """
  A controller: a board plus a link (how the app reaches it). Setting one up
  is just this; its configuration is a separate thing that lives on the
  controller and is managed once connected.

    * `id` — short and random, stable for the controller's life
    * `name` — yours, e.g. "Bench ESP32"
    * `board` — the hardware (`CNC.Boards`): sets the defaults
    * `firmware` — `:fluidnc` for now; recorded for later
    * `link` — how the app reaches it, which can change without touching
      anything else:
        * `%{type: :fluidnc_sim}` — FluidNC as a program on this computer
        * `%{type: :fake_sim}` — the built-in imitation (dev, tests)
        * `%{type: :serial, port: "/dev/cu.usbserial-0001", speed: 115200}`
        * `%{type: :tcp, host: "fluidnc.local", port: 23}`
  """

  @derive {Jason.Encoder, only: [:id, :name, :board, :firmware, :link]}
  defstruct [:id, :name, :board, firmware: :fluidnc, link: %{type: :fake_sim}]

  @type link ::
          %{type: :fluidnc_sim}
          | %{type: :fake_sim}
          | %{type: :serial, port: String.t(), speed: pos_integer}
          | %{type: :tcp, host: String.t(), port: pos_integer}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          board: CNC.Boards.id(),
          firmware: :fluidnc,
          link: link
        }

  @alphabet ~c"abcdefghjkmnpqrstuvwxyz23456789"

  @doc "A new short id: 4 characters, no look-alikes (0/o, 1/l/i)."
  def new_id, do: for(_ <- 1..4, into: "", do: <<Enum.random(@alphabet)>>)

  @doc "A plain map for storage (CubDB), so changes to this struct can't break stored data."
  def to_map(%__MODULE__{} = p),
    do: %{id: p.id, name: p.name, board: p.board, firmware: p.firmware, link: p.link}

  @doc "From a stored map back to a controller; :error if it doesn't fit anymore."
  def from_map(map) when is_map(map), do: map |> Jason.encode!() |> Jason.decode!() |> from_json()

  @doc "From stored JSON (string keys) back to a controller; :error if it doesn't fit."
  def from_json(%{"id" => id, "name" => name, "board" => board, "link" => link} = map) do
    with {:ok, board} <- known_atom(board, CNC.Boards.ids()),
         {:ok, link} <- link_from_json(link) do
      {:ok, %__MODULE__{id: id, name: name, board: board, link: link, firmware: firmware(map)}}
    end
  end

  def from_json(_), do: :error

  defp firmware(%{"firmware" => "fluidnc"}), do: :fluidnc
  defp firmware(_), do: :fluidnc

  defp link_from_json(%{"type" => "fluidnc_sim"}), do: {:ok, %{type: :fluidnc_sim}}
  defp link_from_json(%{"type" => "fake_sim"}), do: {:ok, %{type: :fake_sim}}

  defp link_from_json(%{"type" => "serial", "port" => port} = l) when is_binary(port),
    do: {:ok, %{type: :serial, port: port, speed: Map.get(l, "speed", 115_200)}}

  defp link_from_json(%{"type" => "tcp", "host" => host} = l) when is_binary(host),
    do: {:ok, %{type: :tcp, host: host, port: Map.get(l, "port", 23)}}

  defp link_from_json(_), do: :error

  defp known_atom(string, atoms) do
    case Enum.find(atoms, &(Atom.to_string(&1) == string)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  @doc "A short description of the link, for people."
  def describe_link(%{type: :fluidnc_sim}), do: "FluidNC sim on this computer"
  def describe_link(%{type: :fake_sim}), do: "Fake sim (built in)"
  def describe_link(%{type: :serial, port: port}), do: "USB #{port}"
  def describe_link(%{type: :tcp, host: host, port: port}), do: "Wi-Fi #{host}:#{port}"
end
