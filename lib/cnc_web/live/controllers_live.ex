defmodule CNCWeb.ControllersLive do
  @moduledoc """
  Your controllers: which one the machine is using, switching, changing how
  one is reached, adding and removing. A controller is a board plus a link
  (`CNC.Controllers`); only links its board can use are offered.
  """
  use CNCWeb, :live_view

  on_mount CNCWeb.Pin

  alias CNC.{Boards, Controllers, Machine}
  alias CNC.Controllers.Profile

  @link_labels %{
    fluidnc_sim: "On this computer",
    fake_sim: "Built in",
    serial: "USB",
    tcp: "Wi-Fi"
  }

  @impl true
  def mount(_params, session, socket) do
    cnc = CNCWeb.Instance.from_session(session)

    if connected?(socket) do
      Machine.subscribe(cnc.topic)
      Controllers.subscribe(cnc.controllers_topic)
    end

    {:ok,
     socket
     |> assign(page_title: "Controllers", cnc: cnc, machine: Machine.status(cnc.machine))
     |> assign(editing: nil, edit: %{}, error: nil, ports: Controllers.serial_ports())
     |> assign(add: new_add())
     |> load()}
  end

  @impl true
  def handle_info({:controllers, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:machine, machine}, socket), do: {:noreply, assign(socket, machine: machine)}

  @impl true
  def handle_event("use", %{"id" => id}, socket) do
    case Controllers.select(socket.assigns.cnc.controllers, id) do
      :ok -> {:noreply, socket |> assign(error: nil) |> load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("edit_link", %{"id" => id}, socket) do
    profile = Enum.find(socket.assigns.profiles, &(&1.id == id))
    {:noreply, assign(socket, editing: id, edit: link_params(profile.link), error: nil)}
  end

  def handle_event("cancel_edit", _, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("edit_change", %{"link" => params}, socket),
    do: {:noreply, assign(socket, edit: params)}

  def handle_event("save_link", %{"link" => params}, socket) do
    case Controllers.update_link(
           socket.assigns.cnc.controllers,
           socket.assigns.editing,
           link_attrs(params)
         ) do
      {:ok, _} -> {:noreply, socket |> assign(editing: nil, error: nil) |> load()}
      {:error, reason} -> {:noreply, assign(socket, edit: params, error: error_text(reason))}
    end
  end

  def handle_event("deactivate", _, socket) do
    case Controllers.deactivate(socket.assigns.cnc.controllers) do
      :ok -> {:noreply, socket |> assign(error: nil) |> load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("fork", %{"id" => id}, socket) do
    case Controllers.fork(socket.assigns.cnc.controllers, id) do
      {:ok, _} -> {:noreply, socket |> assign(error: nil) |> load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case Controllers.remove(socket.assigns.cnc.controllers, id) do
      :ok -> {:noreply, socket |> assign(error: nil) |> load()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  # Changing the board resets the link to that board's usual one.
  def handle_event("add_change", %{"add" => params}, socket) do
    params =
      if params["board"] != socket.assigns.add["board"],
        do:
          Map.put(
            params,
            "type",
            params["board"] |> board() |> Boards.default_link() |> to_string()
          ),
        else: params

    {:noreply, assign(socket, add: params, error: nil)}
  end

  def handle_event("add", %{"add" => params}, socket) do
    attrs = %{
      name: String.trim(params["name"] || ""),
      board: board(params["board"]),
      link: link_attrs(params)
    }

    case Controllers.add(socket.assigns.cnc.controllers, attrs) do
      {:ok, _} -> {:noreply, socket |> assign(add: new_add(), error: nil) |> load()}
      {:error, reason} -> {:noreply, assign(socket, add: params, error: error_text(reason))}
    end
  end

  def handle_event("refresh_ports", _, socket),
    do: {:noreply, assign(socket, ports: Controllers.serial_ports())}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="cnc-page">
        <header class="cnc-bar">
          <.link navigate={~p"/"} class="cnc-btn">Back to machine</.link>
          <h1 class="cnc-page-title">Controllers</h1>
          <div class={"cnc-state cnc-state--#{@machine.state}"} role="status">
            {state_word(@machine.state)}
          </div>
        </header>

        <main class="cnc-settings">
          <p class="cnc-sub cnc-settings-intro">
            A controller is a board plus how the app reaches it. Its configuration lives on
            the controller, so changing the link (USB to Wi-Fi, say) keeps it. Connect one
            to drive the machine with it (it starts locked until you unlock or home);
            Disconnect to use none. Fork a sim to get an independent copy to experiment with.
          </p>

          <p :if={@overridden?} class="cnc-note cnc-note--warn">
            CNC_LINK is set, so the machine uses that link and these controllers are
            ignored until the app restarts without it.
          </p>
          <p :if={@error} id="controllers-error" class="cnc-set-error">{@error}</p>

          <section class="cnc-set-group" aria-label="Your controllers">
            <h2 class="cnc-h">Your controllers</h2>
            <p :if={@profiles == []} id="no-controllers" class="cnc-note">
              No controllers yet. Add one below: the FluidNC sim to try things on this
              computer, or your board (USB or Wi-Fi).
            </p>
            <ul class="cnc-ctls" id="controllers">
              <li
                :for={p <- @profiles}
                id={"controller-#{p.id}"}
                class={["cnc-ctl-card", p.id == @active_id && "is-active"]}
              >
                <div class="cnc-ctl-card-head">
                  <h3 class="cnc-ctl-name">{p.name}</h3>
                  <span :if={p.id == @active_id} class="cnc-ctl-tag">
                    {if @machine.connected?, do: "In use, connected", else: "In use, not connected"}
                  </span>
                </div>
                <dl class="cnc-facts">
                  <dt>board</dt>
                  <dd>{Boards.label(p.board)}</dd>
                  <dt>link</dt>
                  <dd>{Profile.describe_link(p.link)}</dd>
                </dl>

                <form
                  :if={@editing == p.id}
                  id={"link-form-#{p.id}"}
                  class="cnc-ctl-form"
                  phx-change="edit_change"
                  phx-submit="save_link"
                >
                  <.link_fields name="link" params={@edit} board={p.board} ports={@ports} />
                  <div class="cnc-row">
                    <button type="button" class="cnc-btn" phx-click="cancel_edit">Cancel</button>
                    <button type="submit" class="cnc-btn cnc-btn--primary">Save link</button>
                  </div>
                </form>

                <div :if={@editing != p.id} class="cnc-row">
                  <button
                    :if={p.id != @active_id}
                    type="button"
                    class="cnc-btn cnc-btn--primary"
                    phx-click="use"
                    phx-value-id={p.id}
                    disabled={@overridden? or @machine.moving?}
                  >
                    Connect
                  </button>
                  <button
                    :if={p.id == @active_id}
                    type="button"
                    class="cnc-btn"
                    phx-click="deactivate"
                    disabled={@overridden? or @machine.moving?}
                    data-confirm={"Stop using #{p.name}? The machine disconnects."}
                  >
                    Disconnect
                  </button>
                  <button
                    :if={length(Boards.links(p.board)) > 1 or p.link.type in [:serial, :tcp]}
                    type="button"
                    class="cnc-btn"
                    phx-click="edit_link"
                    phx-value-id={p.id}
                  >
                    Change link
                  </button>
                  <button
                    :if={p.link.type in [:fluidnc_sim, :fake_sim]}
                    type="button"
                    class="cnc-btn"
                    phx-click="fork"
                    phx-value-id={p.id}
                    title="An independent copy to experiment with"
                  >
                    Fork
                  </button>
                  <button
                    :if={p.id != @active_id}
                    type="button"
                    class="cnc-btn cnc-btn--quiet"
                    phx-click="remove"
                    phx-value-id={p.id}
                    data-confirm={remove_confirm(p)}
                  >
                    Remove
                  </button>
                </div>
              </li>
            </ul>
          </section>

          <section class="cnc-set-group" aria-label="Add a controller">
            <h2 class="cnc-h">Add a controller</h2>
            <form id="add-form" class="cnc-ctl-form" phx-change="add_change" phx-submit="add">
              <label class="cnc-ctl-field">
                <span>Name</span>
                <input
                  name="add[name]"
                  value={@add["name"]}
                  placeholder="Bench ESP32"
                  autocomplete="off"
                />
              </label>
              <label class="cnc-ctl-field">
                <span>Board</span>
                <select name="add[board]">
                  <option
                    :for={{id, label} <- Boards.all()}
                    value={id}
                    selected={to_string(id) == @add["board"]}
                  >
                    {label}
                  </option>
                </select>
              </label>
              <.link_fields name="add" params={@add} board={board(@add["board"])} ports={@ports} />
              <div class="cnc-row">
                <button type="submit" class="cnc-btn cnc-btn--primary">Add controller</button>
              </div>
            </form>
          </section>
        </main>
      </div>
    </Layouts.app>
    """
  end

  # The link choice (only the board's) and its fields.
  attr :name, :string, required: true
  attr :params, :map, required: true
  attr :board, :atom, required: true
  attr :ports, :list, required: true

  defp link_fields(assigns) do
    assigns =
      assign(assigns,
        links: Boards.links(assigns.board),
        type: link_type(assigns.params, assigns.board),
        labels: @link_labels
      )

    ~H"""
    <fieldset class="cnc-ctl-field">
      <legend>Link</legend>
      <div class="cnc-seg">
        <label :for={t <- @links} class={["cnc-btn", t == @type && "is-on"]}>
          <input
            type="radio"
            class="cnc-sr-only"
            name={"#{@name}[type]"}
            value={t}
            checked={t == @type}
          />
          {@labels[t]}
        </label>
      </div>
    </fieldset>

    <div :if={@type == :serial} class="cnc-ctl-field">
      <label for={"#{@name}-port"}>USB port</label>
      <div class="cnc-row">
        <input
          id={"#{@name}-port"}
          name={"#{@name}[port]"}
          value={@params["port"]}
          list={"#{@name}-ports"}
          placeholder="/dev/cu.usbserial-0001"
          autocomplete="off"
        />
        <button type="button" class="cnc-btn cnc-btn--quiet" phx-click="refresh_ports">
          Find ports
        </button>
      </div>
      <datalist id={"#{@name}-ports"}>
        <option :for={{device, info} <- @ports} value={device}>{info}</option>
      </datalist>
      <p :if={@ports == []} class="cnc-sub">No serial ports found. Is the board plugged in?</p>
    </div>

    <div :if={@type == :tcp} class="cnc-ctl-field">
      <label for={"#{@name}-host"}>Wi-Fi host</label>
      <input
        id={"#{@name}-host"}
        name={"#{@name}[host]"}
        value={@params["host"]}
        placeholder="fluidnc.local"
        autocomplete="off"
      />
      <p class="cnc-sub">
        Needs FluidNC's Wi-Fi build on the board. Its telnet port has no password: anyone
        on this network can send it commands.
      </p>
    </div>
    """
  end

  defp load(socket) do
    c = socket.assigns.cnc.controllers
    active = Controllers.active(c)

    assign(socket,
      profiles: Controllers.list(c),
      active_id: active && active.id,
      overridden?: Controllers.overridden?(c)
    )
  end

  defp new_add,
    do: %{"name" => "", "board" => "esp32_devkit", "type" => "serial", "port" => "", "host" => ""}

  defp board(name),
    do: Enum.find(Boards.ids(), :esp32_devkit, &(Atom.to_string(&1) == name))

  defp link_type(params, board) do
    links = Boards.links(board)
    Enum.find(links, hd(links), &(Atom.to_string(&1) == params["type"]))
  end

  defp link_params(%{type: type} = link) do
    %{
      "type" => to_string(type),
      "port" => to_string(Map.get(link, :port, "")),
      "host" => to_string(Map.get(link, :host, ""))
    }
  end

  defp link_attrs(%{"type" => "serial"} = p),
    do: %{type: :serial, port: String.trim(p["port"] || "")} |> drop_blank(:port)

  defp link_attrs(%{"type" => "tcp"} = p),
    do: %{type: :tcp, host: String.trim(p["host"] || "")} |> drop_blank(:host)

  defp link_attrs(%{"type" => "fluidnc_sim"}), do: %{type: :fluidnc_sim}
  defp link_attrs(%{"type" => "fake_sim"}), do: %{type: :fake_sim}
  defp link_attrs(_), do: nil

  defp drop_blank(map, key), do: if(map[key] == "", do: Map.delete(map, key), else: map)

  defp remove_confirm(%Profile{name: name, link: %{type: :fluidnc_sim}}),
    do: "Remove #{name}? Its config and settings are deleted with it."

  defp remove_confirm(%Profile{name: name, link: %{type: :fake_sim}}), do: "Remove #{name}?"

  defp remove_confirm(%Profile{name: name}),
    do: "Remove #{name} from this list? Its config stays on the board."

  defp error_text(:not_forkable),
    do: "Boards can't be forked: a board holds one config. Save config versions instead."

  defp error_text(:moving), do: "Wait for the machine to stop before switching controllers."
  defp error_text(:overridden), do: "CNC_LINK is set, so controllers can't be switched."

  defp error_text(:active),
    do: "That's the controller in use: disconnect it (or switch to another) first."

  defp error_text(:serial_port_required), do: "Choose the USB port the board is on."
  defp error_text(:tcp_host_required), do: "Type the board's Wi-Fi host, like fluidnc.local."
  defp error_text(:invalid), do: "Give the controller a name."
  defp error_text({:link_not_supported, _}), do: "That board can't use that link."
  defp error_text(reason), do: "That didn't work (#{inspect(reason)})."

  defp state_word(state) do
    %{
      disconnected: "Not connected",
      connecting: "Connecting",
      alarm: "Locked",
      idle: "Ready",
      jogging: "Jogging",
      homing: "Homing",
      busy: "Busy"
    }[state]
  end
end
