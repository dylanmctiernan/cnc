defmodule CNCWeb.UI do
  @moduledoc """
  The component kit: every page is built from these, styled by the design
  tokens in app.css (`ui-*` classes), with no one-off CSS of its own.

    * `page_header/1` — a page's title, what it's for, and its actions
    * `section/1` — a titled group on a page
    * `card/1` — one thing (a profile, a controller), optionally selected
    * `button/1` — primary, secondary, quiet or danger; a link with `navigate`/`patch`
    * `tabs/1` — a page's views, each with its own URL and an optional count
    * `pill/1` — a short status (ok, warn, danger, info, neutral)
    * `machine_state/1` — what the machine is doing, as a pill
    * `stop_button/1` — Stop: cancel motion and hold, never refused
    * `dialog/1` — a modal: title, body, actions
    * `empty/1` — nothing here yet, and what to do about it
    * `viewport/1` — the 3D view of the machine (three.js, the `Viewport`
      hook): the page sends it the standard machine-view events ("pos",
      "program", "travel") and answers its "viewport_ready"
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :title, :string, required: true
  attr :id, :string, default: nil
  slot :description
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="ui-page-header" id={@id}>
      <div>
        <h1 class="ui-title">{@title}</h1>
        <p :if={@description != []} class="ui-lede">{render_slot(@description)}</p>
      </div>
      <div :if={@actions != []} class="ui-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr :title, :string, default: nil
  attr :id, :string, default: nil
  attr :rest, :global
  slot :description
  slot :actions
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class="ui-section" id={@id} aria-label={@title} {@rest}>
      <div :if={@title || @actions != []} class="ui-section-head">
        <h2 :if={@title} class="ui-section-title">{@title}</h2>
        <div :if={@actions != []} class="ui-actions">{render_slot(@actions)}</div>
      </div>
      <p :if={@description != []} class="ui-muted">{render_slot(@description)}</p>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, default: nil
  attr :selected, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["ui-card", @selected && "is-selected", @class]} id={@id} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :variant, :string, default: "secondary", values: ~w(primary secondary quiet danger)
  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled type name value form)
  slot :inner_block, required: true

  def button(%{navigate: nil, patch: nil} = assigns) do
    ~H"""
    <button
      type={@rest[:type] || "button"}
      class={["ui-btn", "ui-btn--#{@variant}", "ui-btn--#{@size}", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  def button(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      patch={@patch}
      class={["ui-btn", "ui-btn--#{@variant}", "ui-btn--#{@size}", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :id, :string, default: "tabs"
  attr :label, :string, required: true
  attr :current, :atom, required: true
  attr :items, :list, required: true, doc: "[{key, label, path}] or [{key, label, path, count}]"

  def tabs(assigns) do
    ~H"""
    <nav class="ui-tabs" id={@id} aria-label={@label}>
      <.link
        :for={item <- @items}
        patch={elem(item, 2)}
        id={"tab-#{elem(item, 0)}"}
        class={["ui-tab", @current == elem(item, 0) && "is-current"]}
        aria-current={if(@current == elem(item, 0), do: "page", else: "false")}
      >
        {elem(item, 1)}
        <span :if={tuple_size(item) > 3 and elem(item, 3) > 0} class="ui-count">
          {elem(item, 3)}
        </span>
      </.link>
    </nav>
    """
  end

  attr :tone, :string, default: "neutral", values: ~w(ok warn danger info move neutral)
  attr :id, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def pill(assigns) do
    ~H"""
    <span class={["ui-pill", "ui-pill--#{@tone}"]} id={@id} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  attr :machine, :map, required: true
  attr :id, :string, default: nil

  @doc "What the machine is doing, as a pill: Ready, Locked, Jogging..."
  def machine_state(assigns) do
    ~H"""
    <.pill tone={state_tone(@machine.state)} id={@id} role="status">
      {state_word(@machine.state)}
    </.pill>
    """
  end

  @doc "A machine state in words."
  def state_word(state) do
    %{
      disconnected: "Not connected",
      connecting: "Connecting",
      alarm: "Locked",
      idle: "Ready",
      jogging: "Jogging",
      uploading: "Uploading",
      homing: "Homing",
      busy: "Busy"
    }[state] || to_string(state)
  end

  defp state_tone(:idle), do: "ok"
  defp state_tone(:alarm), do: "danger"
  defp state_tone(s) when s in [:jogging, :homing, :busy], do: "move"
  defp state_tone(s) when s in [:connecting, :uploading], do: "info"
  defp state_tone(_), do: "neutral"

  attr :id, :string, default: "stop"
  attr :disabled, :boolean, default: false
  attr :size, :string, default: "md", values: ~w(md lg)

  @doc "Stop: cancels any jog and holds the machine. Handled by `CNCWeb.Shell`."
  def stop_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class={["ui-stop", "ui-stop--#{@size}"]}
      phx-click="shell:stop"
      disabled={@disabled}
    >
      Stop
    </button>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :on_cancel, :string, required: true
  slot :inner_block, required: true
  slot :actions, required: true

  @doc "A modal: Escape or a click outside cancels."
  def dialog(assigns) do
    ~H"""
    <div class="ui-modal" id={@id} phx-window-keydown={@on_cancel} phx-key="Escape">
      <div
        class="ui-modal-box"
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        phx-click-away={@on_cancel}
      >
        <h2 id={"#{@id}-title"} class="ui-modal-title">{@title}</h2>
        {render_slot(@inner_block)}
        <div class="ui-actions">{render_slot(@actions)}</div>
      </div>
    </div>
    """
  end

  attr :id, :string, default: nil
  slot :inner_block, required: true
  slot :action

  def empty(assigns) do
    ~H"""
    <div class="ui-empty" id={@id}>
      <p>{render_slot(@inner_block)}</p>
      <div :if={@action != []} class="ui-actions">{render_slot(@action)}</div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :travel, :string, required: true, doc: "JSON [[x0, x1], [y0, y1], [z0, z1]]"
  attr :label, :string, default: "3D view of the machine, the toolpath and the tool"
  attr :class, :any, default: nil

  @doc """
  The 3D viewport. Drag to orbit, right-drag (or two fingers) to pan, wheel
  or pinch to zoom; File frames the loaded toolpath, Iso, Top and Front the
  whole machine.
  """
  def viewport(assigns) do
    ~H"""
    <div
      class={["ui-viewport", @class]}
      id={@id}
      phx-hook="Viewport"
      phx-update="ignore"
      data-travel={@travel}
    >
      <canvas role="img" aria-label={@label}></canvas>
      <div class="ui-viewport-views" role="group" aria-label="View">
        <button
          :for={{view, label} <- [file: "File", iso: "Iso", top: "Top", front: "Front"]}
          type="button"
          class="ui-btn ui-btn--sm"
          id={"#{@id}-#{view}"}
          phx-click={JS.dispatch("viewport:view", to: "##{@id}", detail: %{view: view})}
        >
          {label}
        </button>
      </div>
    </div>
    """
  end

  @doc "Collapse or expand the shell's rail (desktop), or open/close it (narrow screens)."
  def toggle_rail(js \\ %JS{}), do: JS.toggle_class(js, "is-collapsed", to: "#shell")
  def toggle_drawer(js \\ %JS{}), do: JS.toggle_class(js, "is-open", to: "#shell")
end
