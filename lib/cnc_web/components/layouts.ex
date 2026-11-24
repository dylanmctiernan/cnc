defmodule CNCWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CNCWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @nav [
    {:machine, "Machine", "hero-cube", "/"},
    {:configuration, "Configuration", "hero-adjustments-horizontal", "/configuration"},
    {:controllers, "Controllers", "hero-cpu-chip", "/controllers"}
  ]

  @doc """
  The workstation shell: a left rail (the app's places, and the machine's
  state with Hold pinned at its foot, so both are always in reach), and the
  page beside it. The rail collapses to icons. `machine` comes from
  `CNCWeb.Shell` (`@shell_machine`).

  The workstation is for desktop screens (at least 1024 × 600); phones and
  tablets have the pendant. Below that size, instead of a broken layout,
  the shell says so, points to the pendant and keeps the machine's state
  and Hold in reach; "Use anyway" shows the workstation regardless (for
  this browser session).
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current, :atom, default: nil, doc: "the rail item for this page"
  attr :machine, :map, default: nil, doc: "the machine's state, for the rail"
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :nav, @nav)

    ~H"""
    <div id="shell" class="ui-shell">
      <aside class="ui-rail" aria-label="Main">
        <div class="ui-rail-head">
          <button
            type="button"
            class="ui-rail-toggle"
            phx-click={CNCWeb.UI.toggle_rail()}
            aria-label="Collapse or expand the menu"
          >
            <.icon name="hero-bars-3" class="ui-nav-icon" />
          </button>
          <span class="ui-brand">CNC</span>
        </div>
        <nav class="ui-nav">
          <.link
            :for={{key, label, icon, path} <- @nav}
            navigate={path}
            id={"nav-#{key}"}
            class={["ui-nav-item", @current == key && "is-current"]}
            aria-current={if(@current == key, do: "page", else: "false")}
            title={label}
          >
            <.icon name={icon} class="ui-nav-icon" />
            <span class="ui-nav-label">{label}</span>
          </.link>
        </nav>
        <div class="ui-rail-foot">
          <.link navigate="/pendant" id="nav-pendant" class="ui-nav-item" title="Pendant">
            <.icon name="hero-device-phone-mobile" class="ui-nav-icon" />
            <span class="ui-nav-label">Pendant</span>
          </.link>
          <%!-- The app's lock (back to the PIN), not the machine's: only when
               a PIN is set --%>
          <.link
            :if={CNCWeb.Pin.configured()}
            href="/pin"
            method="delete"
            id="nav-lock"
            class="ui-nav-item"
            title="Lock screen: back to the PIN"
          >
            <.icon name="hero-lock-closed" class="ui-nav-icon" />
            <span class="ui-nav-label">Lock screen</span>
          </.link>
          <div :if={@machine} class="ui-rail-machine">
            <CNCWeb.UI.machine_state machine={@machine} id="rail-state" />
            <CNCWeb.UI.hold_button id="rail-hold" />
          </div>
        </div>
      </aside>

      <section id="too-small" class="ui-too-small" phx-hook=".UseAnyway" aria-label="Screen too small">
        <div class="ui-too-small-box">
          <.icon name="hero-computer-desktop" class="ui-too-small-icon" />
          <h1 class="ui-modal-title">This window is too small for the workstation</h1>
          <p class="ui-muted">
            The workstation is laid out for a desktop screen, at least 1024 × 600. On a
            phone or tablet, use the pendant: jogging, Hold and Resume.
          </p>
          <div :if={@machine} class="ui-too-small-machine">
            <CNCWeb.UI.machine_state machine={@machine} id="small-state" />
            <CNCWeb.UI.hold_button id="small-hold" size="lg" />
          </div>
          <div class="ui-actions">
            <CNCWeb.UI.button variant="primary" navigate="/pendant" id="small-pendant">
              Open the pendant
            </CNCWeb.UI.button>
            <CNCWeb.UI.button variant="quiet" id="small-anyway" data-anyway>
              Use anyway
            </CNCWeb.UI.button>
          </div>
        </div>
      </section>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".UseAnyway">
        // "Use anyway": remembered for this browser session, on <html> (outside
        // what LiveView patches), so it holds across pages.
        const KEY = "cnc:use-anyway"
        export default {
          mounted() {
            try {
              if (sessionStorage.getItem(KEY)) document.documentElement.classList.add("cnc-anyway")
            } catch (_) {}
            this.el.querySelector("[data-anyway]")?.addEventListener("click", () => {
              document.documentElement.classList.add("cnc-anyway")
              try { sessionStorage.setItem(KEY, "1") } catch (_) {}
            })
          }
        }
      </script>

      <main class="ui-main">
        {render_slot(@inner_block)}
      </main>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The pendant's layout: the whole screen for one task, no rail.
  """
  attr :flash, :map, required: true
  slot :inner_block, required: true

  def pendant(assigns) do
    ~H"""
    <div class="ui-pendant-shell">{render_slot(@inner_block)}</div>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
