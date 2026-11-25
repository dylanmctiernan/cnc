defmodule CNCWeb.SettingsLive do
  @moduledoc """
  The app's settings (`CNCApp.Settings`): how it looks and behaves. The
  machine's own setup is under Configuration. Changes apply at once, on
  every open screen; there's nothing to save.
  """
  use CNCWeb, :live_view

  alias CNCApp.Settings

  @impl true
  def mount(_params, session, socket) do
    cnc = CNCWeb.Instance.from_session(session)
    if connected?(socket), do: Settings.subscribe(cnc.db)

    {:ok, assign(socket, page_title: "Settings", cnc: cnc, settings: Settings.all(cnc.db))}
  end

  @impl true
  def handle_info({:app_settings, settings}, socket),
    do: {:noreply, assign(socket, settings: settings)}

  def handle_info({:machine, _}, socket), do: {:noreply, socket}

  @impl true
  # (Not phx-value-value: a button's own value would be sent under "value" too)
  def handle_event("set", %{"key" => "jog_trail", "to" => v}, socket)
      when v in ~w(true false) do
    {:ok, settings} = Settings.put(socket.assigns.cnc.db, :jog_trail, v == "true")
    {:noreply, assign(socket, settings: settings)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:settings} machine={@shell_machine}>
      <div class="ui-page" id="settings">
        <UI.page_header title="Settings">
          <:description>
            How the app looks and behaves. The machine's own setup is under
            Configuration. Changes apply straight away, on every open screen.
          </:description>
        </UI.page_header>

        <UI.section title="Display" id="settings-display">
          <div class="ui-setting" id="setting-jog-trail">
            <div>
              <p class="ui-setting-name">Jog trail</p>
              <p class="ui-muted">
                While you jog, the 2D map draws the path the tool moves, fading over time.
              </p>
            </div>
            <div class="cnc-seg cnc-seg--small" role="group" aria-label="Jog trail">
              <button
                :for={{v, label} <- [{false, "Off"}, {true, "On"}]}
                type="button"
                class="cnc-btn"
                id={"jog-trail-#{if v, do: "on", else: "off"}"}
                phx-click="set"
                phx-value-key="jog_trail"
                phx-value-to={to_string(v)}
                aria-pressed={to_string(@settings.jog_trail == v)}
              >
                {label}
              </button>
            </div>
          </div>
        </UI.section>
      </div>
    </Layouts.app>
    """
  end
end
