defmodule CNCWeb.UI do
  @moduledoc """
  The component kit: every page is built from these, styled by the design
  tokens in app.css (`ui-*` classes), with no one-off CSS of its own.

  Rules every screen follows:

    * **Nothing floats over content.** Controls get their own strip (the
      map's toolbar), messages the fixed message line; never a button or
      note laid over a drawing, a readout or another control. Exceptions:
      modal dialogs (they take over a task on purpose) and a cover that
      replaces a control that can't be used (the pendant's stick).
    * **No layout shift.** Controls never appear, disappear or change size
      under the operator's hand: something that's sometimes unavailable is
      disabled, not removed (Resume, the zoom's File); labels that change
      keep their size; messages go in the message line, which is always
      there. `mix e2e.layout` checks this
      in a browser against the dev server; add a step for each new
      interaction (assets/e2e/layout_shift.mjs).
    * **Grey is normal, colour means attention** (ISA-101): a calm state
      gets a small mark, not a coloured block; never colour alone.
    * **Hold is always in reach** and never covered.
    * **Desktop first:** the workstation is for screens of at least
      1024 x 600 (a tablet sideways counts); phones and tablets upright get
      the pendant (`Layouts.app` says so below that size).

    * `page_header/1` — a page's title, what it's for, and its actions
    * `section/1` — a titled group on a page
    * `card/1` — one thing (a profile, a controller), optionally selected
    * `button/1` — primary, secondary, quiet or danger; a link with `navigate`/`patch`
    * `tabs/1` — a page's views, each with its own URL and an optional count
    * `pill/1` — a short status (ok, warn, danger, info, neutral)
    * `machine_state/1` — what the machine is doing, as a pill
    * `hold_button/1` — Hold: pause all motion now (feed hold), never refused
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

  @doc """
  What the machine is doing, as a pill: Ready, On hold, Locked, Jogging...
  Grey is normal and colour means attention (ISA-101): Ready is a quiet
  pill with a green dot; on hold is amber, locked red, moving blue.
  """
  def machine_state(assigns) do
    assigns = assign(assigns, :held, held(assigns.machine))

    ~H"""
    <.pill tone={if(@held, do: "warn", else: state_tone(@machine.state))} id={@id} role="status">
      <span :if={@machine.state == :idle} class="ui-dot ui-dot--ok" aria-hidden="true"></span>
      {@held || state_word(@machine.state)}
    </.pill>
    """
  end

  # Busy because it's held (or the door is open): the controller's own word
  defp held(%{state: :busy, controller: :hold}), do: "On hold"
  defp held(%{state: :busy, controller: :door}), do: "Door open"
  defp held(_), do: nil

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

  defp state_tone(:idle), do: "neutral"
  defp state_tone(:alarm), do: "danger"
  defp state_tone(s) when s in [:jogging, :homing, :busy], do: "move"
  defp state_tone(s) when s in [:connecting, :uploading], do: "info"
  defp state_tone(_), do: "neutral"

  attr :id, :string, default: "hold"
  attr :size, :string, default: "md", values: ~w(md lg)
  attr :class, :any, default: nil

  @doc """
  Hold: pauses all motion now (a feed hold, which also cancels a jog). The
  machine decelerates and stops on its path with the position kept; Resume
  carries on. Not an e-stop: the spindle keeps turning, and the job isn't
  cancelled (Reset does that). Never disabled. Handled by `CNCWeb.Shell`.
  """
  def hold_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class={["ui-hold", "ui-hold--#{@size}", @class]}
      phx-click="shell:hold"
      title="Pause all motion now (Esc). Resume carries on."
    >
      Hold
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

  attr :views, :boolean,
    default: true,
    doc:
      "its own File/Iso/Top/Front buttons; false when the page puts `viewport_views/1` in a toolbar"

  @doc """
  The 3D viewport. Drag to orbit, right-drag (or two fingers) to pan, wheel
  or pinch to zoom; Iso, Top and Front frame the loaded part (or the whole
  machine without one), Machine the whole travel.
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
      <.viewport_views :if={@views} for={@id} class="ui-viewport-views" />
    </div>
    """
  end

  attr :for, :string, required: true, doc: "the viewport's id"
  attr :class, :any, default: nil

  @doc "The 3D view's standard views, for a toolbar: Iso, Top and Front frame the part (if one is loaded), Machine the whole travel."
  def viewport_views(assigns) do
    ~H"""
    <div class={["cnc-seg cnc-seg--small", @class]} role="group" aria-label="View">
      <button
        :for={{view, label} <- [iso: "Iso", top: "Top", front: "Front", machine: "Machine"]}
        type="button"
        class="cnc-btn"
        id={"#{@for}-#{view}"}
        phx-click={JS.dispatch("viewport:view", to: "##{@for}", detail: %{view: view})}
      >
        {label}
      </button>
    </div>
    """
  end

  @doc "Collapse or expand the shell's rail."
  def toggle_rail(js \\ %JS{}), do: JS.toggle_class(js, "is-collapsed", to: "#shell")
end
