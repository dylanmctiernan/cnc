defmodule CNC.Boards do
  @moduledoc """
  The catalogue of boards: the hardware a controller runs on, and its
  defaults: which pins drive
  which motor, the stepping engine, whether it has switches. Combined with
  the machine (`priv/fluidnc/config.yaml.eex`: travel, speeds, homing) into
  a new controller's starting `config.yaml`. Pure data: no processes, no
  dependencies.

  Each board also says which links it can use (`links/1`, the usual one
  first): that's a property of the hardware. Wi-Fi needs FluidNC's Wi-Fi
  build on the board (the bench ESP32 is flashed with the USB-only one).

  Boards:

    * `:fake_sim` — the built-in imitation (dev, tests); no FluidNC config.
    * `:fluidnc_sim` — FluidNC as a program on this computer (dev). Its
      native build accepts ESP32-S3 pin numbers only, has no RMT engine
      (timed: moves in real time), and its inputs never trigger, so no
      switches: homing is "set position only".
    * `:esp32_devkit` — the bench ESP32 (ELEGOO 30-pin ESP-WROOM-32). Pins
      avoid 6-11 (flash), 0/2/5/12/15 (boot strapping), 1/3 (USB serial) and
      34-39 (input only, no pull-ups): step/dir X 25/26, Y 27/14, Z 33/32,
      shared disable 13; buttons to GND with internal pull-ups X 16, Y 17,
      Z 4, probe 18.

    * `:six_x` — the 6x CNC Controller (the router's board), for external
      drivers (the DM542Ts). Pins from FluidNC's example config,
      bdring/fluidnc-config-files `contributed/6x_CNC_Controller/6x_default.yaml`
      (commit f792c68): step/dir/enable through the I2S shift register
      (`I2SO.n`, engine I2S_STREAM), motor sockets 0/1/2 for X/Y/Z, each
      socket's input (gpio 2, 26, 33) as that axis's limit switch, probe
      gpio.39, tool setter gpio.36. Z homes up here, so its input is the
      positive-end limit (the example uses the negative end). Spindle and
      coolant outputs aren't configured yet.
  """

  use Boundary, deps: [], exports: []

  @type id :: :fake_sim | :fluidnc_sim | :esp32_devkit | :six_x
  @type link_type :: :fake_sim | :fluidnc_sim | :serial | :tcp

  @six_x_extra """
  i2so:
    bck_pin: gpio.22
    data_pin: gpio.21
    ws_pin: gpio.17

  spi:
    miso_pin: gpio.19
    mosi_pin: gpio.23
    sck_pin: gpio.18

  sdcard:
    card_detect_pin: NO_PIN
    cs_pin: gpio.5
  """

  @boards %{
    fake_sim: %{
      label: "Fake sim",
      firmware: :fluidnc,
      links: [:fake_sim],
      engine: "timed",
      switches?: false,
      pins: %{
        x_step: "gpio.1",
        x_dir: "gpio.2",
        y_step: "gpio.3",
        y_dir: "gpio.4",
        z_step: "gpio.5",
        z_dir: "gpio.6"
      }
    },
    fluidnc_sim: %{
      label: "FluidNC sim",
      firmware: :fluidnc,
      links: [:fluidnc_sim],
      engine: "timed",
      switches?: false,
      pins: %{
        x_step: "gpio.1",
        x_dir: "gpio.2",
        y_step: "gpio.3",
        y_dir: "gpio.4",
        z_step: "gpio.5",
        z_dir: "gpio.6"
      }
    },
    esp32_devkit: %{
      label: "ESP32 DevKit",
      firmware: :fluidnc,
      links: [:serial, :tcp],
      engine: "RMT",
      switches?: true,
      pins: %{
        disable: "gpio.13",
        x_step: "gpio.25",
        x_dir: "gpio.26",
        y_step: "gpio.27",
        y_dir: "gpio.14",
        z_step: "gpio.33",
        z_dir: "gpio.32",
        x_limit: "gpio.16:low:pu",
        y_limit: "gpio.17:low:pu",
        z_limit: "gpio.4:low:pu",
        probe: "gpio.18:low:pu"
      }
    },
    six_x: %{
      label: "6x CNC Controller",
      firmware: :fluidnc,
      links: [:serial, :tcp],
      engine: "I2S_STREAM",
      switches?: true,
      extra: @six_x_extra,
      pins: %{
        x_step: "I2SO.2",
        x_dir: "I2SO.1",
        x_disable: "I2SO.0",
        y_step: "I2SO.5",
        y_dir: "I2SO.4",
        y_disable: "I2SO.7",
        z_step: "I2SO.10",
        z_dir: "I2SO.9",
        z_disable: "I2SO.8",
        x_limit: "gpio.2:low:pu",
        y_limit: "gpio.26:low:pu",
        z_limit: "gpio.33:low",
        probe: "gpio.39:low",
        toolsetter: "gpio.36:low"
      }
    }
  }

  @doc "All boards, `[{id, label}]`, in a stable order."
  def all,
    do: for(id <- [:fluidnc_sim, :esp32_devkit, :six_x, :fake_sim], do: {id, @boards[id].label})

  def ids, do: Map.keys(@boards)

  @doc "A board's defaults (raises on an unknown board)."
  def get!(id), do: Map.fetch!(@boards, id)

  def label(id), do: get!(id).label

  @doc "The links this board can use, the usual one first."
  @spec links(id) :: [link_type]
  def links(id), do: get!(id).links

  @doc "The kind of link a new controller on this board uses by default."
  def default_link(id), do: hd(links(id))

  @doc """
  Whether a config setting (a path like `axes/x/motor0/standard_stepper/step_pin`)
  is wiring: fixed by the board (its pins, stepping engine, buses) rather
  than tuned. FluidNC doesn't change these while running; they change in a
  config file, after a restart.

      iex> CNC.Boards.wiring?("axes/x/motor0/standard_stepper/step_pin")
      true
      iex> CNC.Boards.wiring?("stepping/engine")
      true
      iex> CNC.Boards.wiring?("axes/x/max_rate_mm_per_min")
      false
  """
  @wiring_sections ~w(stepping i2so spi sdcard uart1 uart2 uart_channel1 uart_channel2)
  def wiring?(path) do
    path = String.downcase(path)
    [section | _] = String.split(path, "/")
    String.ends_with?(path, "_pin") or section in @wiring_sections
  end

  @doc """
  A pin as FluidNC means it, for comparing: lower case, attributes in a
  fixed order (`gpio.16:pu:low` and `GPIO.16:low:pu` are the same pin).
  """
  def normalize_pin(value) do
    [pin | attrs] = value |> String.trim() |> String.downcase() |> String.split(":")
    Enum.join([pin | Enum.sort(attrs)], ":")
  end

  @doc "The starting config.yaml for a controller on this board."
  @spec config(id) :: String.t()
  def config(id) do
    board = get!(id)

    EEx.eval_file(template(),
      assigns: [
        board: board.label,
        engine: board.engine,
        switches?: board.switches?,
        pins: board.pins,
        extra: Map.get(board, :extra)
      ]
    )
  end

  defp template, do: Application.app_dir(:cnc, "priv/fluidnc/config.yaml.eex")
end
