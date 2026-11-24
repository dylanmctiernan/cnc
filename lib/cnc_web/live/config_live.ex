defmodule CNCWeb.ConfigLive do
  @moduledoc """
  One controller's configuration (`/controllers/:id/configuration`): the
  config files on it, which one it loads, reading one, saving what's running
  as a new file, switching (the controller restarts) and deleting. Needs that
  controller connected; otherwise it offers to connect it.
  """
  use CNCWeb, :live_view

  on_mount CNCWeb.Pin

  alias CNC.{Controllers, Machine}
  alias CNC.Controllers.Config

  @impl true
  def mount(%{"id" => id}, session, socket) do
    cnc = CNCWeb.Instance.from_session(session)

    if connected?(socket) do
      Machine.subscribe(cnc.topic)
      Controllers.subscribe(cnc.controllers_topic)
    end

    case Enum.find(Controllers.list(cnc.controllers), &(&1.id == id)) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "There's no controller #{id}.")
         |> push_navigate(to: ~p"/controllers")}

      controller ->
        {:ok,
         socket
         |> assign(page_title: "#{controller.name} configuration", cnc: cnc)
         |> assign(controller: controller, machine: Machine.status(cnc.machine))
         |> assign(files: nil, active_file: nil, viewing: nil, text: nil, error: nil)
         |> assign(save_name: "", working: nil)
         |> refresh_active()
         |> maybe_load()}
    end
  end

  @impl true
  def handle_info({:machine, machine}, socket) do
    was_ready? = ready?(socket.assigns)
    socket = assign(socket, machine: machine)

    # Came back (connected, or after a restart): read the files again.
    if ready?(socket.assigns) and not was_ready?,
      do: {:noreply, socket |> assign(working: nil) |> maybe_load()},
      else: {:noreply, socket}
  end

  def handle_info({:controllers, _}, socket), do: {:noreply, refresh_active(socket)}

  @impl true
  def handle_event("connect", _, socket) do
    case Controllers.select(socket.assigns.cnc.controllers, socket.assigns.controller.id) do
      :ok -> {:noreply, socket |> assign(error: nil) |> refresh_active()}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("view", %{"name" => name}, socket) do
    case Config.show(machine(socket), name) do
      {:ok, text} -> {:noreply, assign(socket, viewing: name, text: text, error: nil)}
      {:error, reason} -> {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("close_view", _, socket),
    do: {:noreply, assign(socket, viewing: nil, text: nil)}

  def handle_event("save_change", %{"save" => %{"name" => name}}, socket),
    do: {:noreply, assign(socket, save_name: name)}

  def handle_event("save_as", %{"save" => %{"name" => name}}, socket) do
    with {:ok, name} <- Config.valid_name(name),
         false <- Enum.any?(socket.assigns.files || [], &(&1.name == name)) && {:error, :exists},
         {:ok, name} <- Config.save_running_as(machine(socket), name) do
      {:noreply,
       socket
       |> assign(save_name: "", error: nil)
       |> put_flash(:info, "Saved the running config as #{name}.")
       |> maybe_load()}
    else
      {:error, reason} -> {:noreply, assign(socket, save_name: name, error: error_text(reason))}
    end
  end

  def handle_event("activate", %{"name" => name}, socket) do
    case Config.activate(machine(socket), name) do
      :ok ->
        {:noreply,
         assign(socket, working: "Restarting with #{name}…", viewing: nil, text: nil, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  def handle_event("delete", %{"name" => name}, socket) do
    case Config.delete(machine(socket), name) do
      :ok ->
        socket = if socket.assigns.viewing == name, do: assign(socket, viewing: nil), else: socket
        {:noreply, socket |> assign(error: nil) |> maybe_load()}

      {:error, reason} ->
        {:noreply, assign(socket, error: error_text(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="cnc-page">
        <header class="cnc-bar">
          <.link navigate={~p"/controllers"} class="cnc-btn" id="back-to-controllers">
            Controllers
          </.link>
          <h1 class="cnc-page-title">{@controller.name} configuration</h1>
          <div class={"cnc-state cnc-state--#{@machine.state}"} role="status">
            {state_word(@machine.state)}
          </div>
        </header>

        <main class="cnc-settings">
          <p class="cnc-sub cnc-settings-intro">
            The configuration lives on the controller as files. It loads one when it starts;
            keep variations side by side and switch between them (the controller restarts
            and comes back locked).
          </p>

          <p :if={@error} id="config-error" class="cnc-set-error">{@error}</p>

          <%= cond do %>
            <% not @active? -> %>
              <section class="cnc-set-group" id="config-not-connected">
                <p class="cnc-note">
                  {@controller.name} isn't the controller in use. Connect it to see and change
                  its configuration.
                </p>
                <div class="cnc-row">
                  <button
                    type="button"
                    id="config-connect"
                    class="cnc-btn cnc-btn--primary"
                    phx-click="connect"
                    disabled={@machine.moving?}
                  >
                    Connect {@controller.name}
                  </button>
                </div>
              </section>
            <% @working -> %>
              <p class="cnc-note" id="config-working">{@working}</p>
            <% not ready?(assigns) -> %>
              <p class="cnc-note" id="config-waiting">
                {waiting_text(@machine.state)}
              </p>
            <% true -> %>
              <section class="cnc-set-group" aria-label="Config files">
                <h2 class="cnc-h">Config files</h2>
                <p :if={@files == []} class="cnc-note">No config files found on the controller.</p>
                <ul class="cnc-ctls" id="config-files">
                  <li
                    :for={f <- @files || []}
                    id={"config-file-#{dom_id(f.name)}"}
                    class={["cnc-ctl-card", f.name == @active_file && "is-active"]}
                  >
                    <div class="cnc-ctl-card-head">
                      <h3 class="cnc-ctl-name">{f.name}</h3>
                      <span :if={f.name == @active_file} class="cnc-ctl-tag">Loaded at start</span>
                      <span class="cnc-ctl-size">{size(f.size)}</span>
                    </div>
                    <div class="cnc-row">
                      <button
                        type="button"
                        class="cnc-btn"
                        phx-click={if @viewing == f.name, do: "close_view", else: "view"}
                        phx-value-name={f.name}
                      >
                        {if @viewing == f.name, do: "Hide", else: "View"}
                      </button>
                      <button
                        :if={f.name != @active_file}
                        type="button"
                        class="cnc-btn cnc-btn--primary"
                        phx-click="activate"
                        phx-value-name={f.name}
                        disabled={@machine.moving?}
                        data-confirm={"Switch to #{f.name}? The controller restarts and comes back locked."}
                      >
                        Use this config
                      </button>
                      <button
                        :if={f.name != @active_file}
                        type="button"
                        class="cnc-btn cnc-btn--quiet"
                        phx-click="delete"
                        phx-value-name={f.name}
                        data-confirm={"Delete #{f.name} from the controller?"}
                      >
                        Delete
                      </button>
                    </div>
                    <pre :if={@viewing == f.name} class="cnc-config-text" id="config-text">{@text}</pre>
                  </li>
                </ul>
              </section>

              <section class="cnc-set-group" aria-label="Save the running config">
                <h2 class="cnc-h">Save the running config as a new file</h2>
                <p class="cnc-sub">
                  A copy of what the controller is running now, to try changes on without
                  touching {@active_file || "the current file"}.
                </p>
                <form
                  id="save-as-form"
                  class="cnc-ctl-form"
                  phx-change="save_change"
                  phx-submit="save_as"
                >
                  <label class="cnc-ctl-field">
                    <span>File name</span>
                    <input
                      name="save[name]"
                      value={@save_name}
                      placeholder="fast-accel.yaml"
                      autocomplete="off"
                    />
                  </label>
                  <div class="cnc-row">
                    <button type="submit" class="cnc-btn cnc-btn--primary">Save as new file</button>
                  </div>
                </form>
              </section>
          <% end %>
        </main>
      </div>
    </Layouts.app>
    """
  end

  defp machine(socket), do: socket.assigns.cnc.machine

  # This controller in use and the machine ready for commands.
  defp ready?(assigns),
    do:
      assigns.active? and assigns.machine.connected? and assigns.machine.state in [:alarm, :idle]

  defp refresh_active(socket) do
    active = Controllers.active(socket.assigns.cnc.controllers)
    assign(socket, active?: active != nil and active.id == socket.assigns.controller.id)
  end

  defp maybe_load(socket) do
    if connected?(socket) and ready?(socket.assigns) do
      case Config.files(machine(socket)) do
        {:ok, %{files: files, active: active}} ->
          assign(socket, files: files, active_file: active)

        {:error, reason} ->
          assign(socket, error: error_text(reason))
      end
    else
      socket
    end
  end

  defp waiting_text(:disconnected), do: "Not connected yet: waiting for the controller."
  defp waiting_text(:connecting), do: "Connecting…"
  defp waiting_text(_), do: "The machine is moving: the configuration is available once it stops."

  defp dom_id(name), do: String.replace(name, ~r/[^A-Za-z0-9_-]/, "-")

  defp size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"

  defp error_text(:invalid_name),
    do: "Use letters, digits, - and _ for the file name (it ends in .yaml)."

  defp error_text(:exists), do: "There's already a file with that name."
  defp error_text(:active), do: "That's the file the controller loads: switch to another first."
  defp error_text(:not_found), do: "That file isn't on the controller."
  defp error_text(:moving), do: "The machine is moving: stop it first."
  defp error_text(:overridden), do: "CNC_LINK is set, so the machine uses that link instead."
  defp error_text(:reset), do: "The controller reset before answering. Try again."
  defp error_text({:invalid_state, _}), do: "The controller is busy: try again once it's idle."
  defp error_text(code) when is_integer(code), do: "The controller refused it (error #{code})."
  defp error_text(other), do: "That didn't work: #{inspect(other)}."

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
