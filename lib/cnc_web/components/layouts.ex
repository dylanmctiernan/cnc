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
  page beside it. The rail collapses to icons; on narrow screens it's a top
  bar with a drawer. `machine` comes from `CNCWeb.Shell` (`@shell_machine`).
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
          <div :if={@machine} class="ui-rail-machine">
            <CNCWeb.UI.machine_state machine={@machine} id="rail-state" />
            <CNCWeb.UI.hold_button id="rail-hold" />
          </div>
        </div>
      </aside>

      <div class="ui-topbar">
        <button
          type="button"
          class="ui-rail-toggle"
          phx-click={CNCWeb.UI.toggle_drawer()}
          aria-label="Menu"
        >
          <.icon name="hero-bars-3" class="ui-nav-icon" />
        </button>
        <span class="ui-brand">CNC</span>
        <span class="ui-spacer"></span>
        <CNCWeb.UI.machine_state :if={@machine} machine={@machine} id="top-state" />
        <CNCWeb.UI.hold_button :if={@machine} id="top-hold" />
      </div>

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
