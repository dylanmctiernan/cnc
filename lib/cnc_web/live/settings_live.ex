defmodule CNCWeb.SettingsLive do
  @moduledoc """
  Controller settings: grouped and explained, edited in place, reviewed as a
  diff, confirmed, then written. Results show per setting and the controller
  is read back afterwards, so what's shown is what it actually stored.
  """
  use CNCWeb, :live_view

  on_mount CNCWeb.Pin

  alias CNC.{Machine, Settings}
  alias CNC.Machine.State

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Machine.subscribe()
    machine = Machine.status()

    {:ok,
     socket
     |> assign(page_title: "Settings", machine: machine, edits: %{}, errors: %{})
     |> assign(reviewing?: false, write_error: nil)
     |> load_settings()}
  end

  @impl true
  def handle_info({:machine, %State{} = machine}, socket) do
    socket =
      if machine.settings_rev != socket.assigns.machine.settings_rev,
        do: load_settings(socket),
        else: socket

    {:noreply, assign(socket, machine: machine)}
  end

  @impl true
  def handle_event("edit", %{"s" => values}, socket) do
    current = socket.assigns.settings

    # The form sends every field; only the ones changed from the
    # controller's value are checked (some stored values, e.g. blank text
    # settings, wouldn't pass and aren't being edited).
    # LiveView also sends "_unused_<n>" markers for untouched fields: skip
    # anything that isn't a setting number.
    {edits, errors} =
      values
      |> Enum.flat_map(fn {key, value} ->
        case Integer.parse(key) do
          {n, ""} -> [{n, value}]
          _ -> []
        end
      end)
      |> Enum.reject(fn {n, value} -> value == current[n] end)
      |> Enum.reduce({%{}, %{}}, fn {n, value}, {edits, errors} ->
        case Settings.validate(n, value) do
          {:ok, v} ->
            if Settings.diff(current, %{n => v}) == [],
              do: {edits, errors},
              else: {Map.put(edits, n, v), errors}

          {:error, reason} ->
            {Map.put(edits, n, value), Map.put(errors, n, reason)}
        end
      end)

    {:noreply, assign(socket, edits: edits, errors: errors, write_error: nil)}
  end

  def handle_event("discard", _, socket),
    do: {:noreply, assign(socket, edits: %{}, errors: %{}, reviewing?: false) |> bump_form()}

  def handle_event("review", _, %{assigns: %{errors: errors, edits: edits}} = socket)
      when errors == %{} and edits != %{},
      do: {:noreply, assign(socket, reviewing?: true)}

  def handle_event("review", _, socket), do: {:noreply, socket}
  def handle_event("back", _, socket), do: {:noreply, assign(socket, reviewing?: false)}

  def handle_event("write", _, socket) do
    changes = for {n, _from, to} <- changes(socket.assigns), do: {n, to}

    case Machine.write_settings(changes) do
      :ok ->
        {:noreply, assign(socket, edits: %{}, reviewing?: false, write_error: nil) |> bump_form()}

      {:error, :moving} ->
        {:noreply, assign(socket, write_error: "Wait for the machine to stop, then write again.")}

      {:error, {:invalid_state, _}} ->
        {:noreply,
         assign(socket,
           write_error: "Settings can only be written when the machine is Ready or Locked."
         )}

      {:error, :invalid_value} ->
        {:noreply, assign(socket, write_error: "One of the values can't be sent.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="cnc-page">
        <header class="cnc-bar">
          <.link navigate={~p"/"} class="cnc-btn">Back to machine</.link>
          <h1 class="cnc-page-title">Controller settings</h1>
          <div class={"cnc-state cnc-state--#{@machine.state}"} role="status">
            {state_word(@machine.state)}
          </div>
          <span :if={@machine.controller_info.simulated?} class="cnc-sim">Simulator</span>
        </header>

        <main class="cnc-settings">
          <p class="cnc-sub cnc-settings-intro">
            These live on the controller and survive restarts. Edit values, review the changes,
            then write them. Writing works when the machine is Ready or Locked.
          </p>

          <p :if={@settings == %{}} class="cnc-note">
            No settings yet: they're read when the controller connects.
          </p>

          <form id={"settings-form-#{@form_rev}"} phx-change="edit" phx-submit="review">
            <section :for={{group, items} <- @grouped} class="cnc-set-group">
              <h2 class="cnc-h">{group}</h2>
              <div
                :for={item <- items}
                class={[
                  "cnc-set-row",
                  Map.has_key?(@edits, item.n) && "is-changed",
                  Map.has_key?(@errors, item.n) && "is-invalid"
                ]}
              >
                <label for={"set-#{item.n}"} class="cnc-set-label">
                  <span class="cnc-set-n">${item.n}</span>
                  <span class="cnc-set-name">{item.name}</span>
                  <span :if={item.help != ""} class="cnc-set-help">{item.help}</span>
                </label>
                <div class="cnc-set-input">
                  <input
                    id={"set-#{item.n}"}
                    name={"s[#{item.n}]"}
                    value={Map.get(@edits, item.n, item.value)}
                    inputmode="decimal"
                    autocomplete="off"
                    spellcheck="false"
                    aria-describedby={Map.has_key?(@errors, item.n) && "err-#{item.n}"}
                  />
                  <span class="cnc-unit">{item.unit}</span>
                  <span
                    :if={result = @machine.settings_write[item.n]}
                    class={"cnc-set-result #{result_class(result)}"}
                  >
                    {result_text(result)}
                  </span>
                </div>
                <p :if={err = @errors[item.n]} id={"err-#{item.n}"} class="cnc-set-error">{err}</p>
              </div>
            </section>
          </form>
        </main>

        <footer class="cnc-review-bar">
          <p :if={@write_error} class="cnc-set-error">{@write_error}</p>
          <span>{pluralize(map_size(@edits), "change")}</span>
          <button type="button" class="cnc-btn" phx-click="discard" disabled={@edits == %{}}>
            Discard
          </button>
          <button
            type="button"
            class="cnc-btn cnc-btn--primary"
            phx-click="review"
            disabled={@edits == %{} or @errors != %{}}
          >
            Review changes
          </button>
        </footer>

        <div :if={@reviewing?} class="cnc-review" role="dialog" aria-labelledby="review-title">
          <div class="cnc-review-box">
            <h2 id="review-title" class="cnc-page-title">Write to the controller?</h2>
            <table class="cnc-review-table">
              <thead>
                <tr>
                  <th>Setting</th>
                  <th>Now</th>
                  <th>New</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{n, from, to} <- changes(assigns)}>
                  <td>${n} {Settings.spec(n).name}</td>
                  <td class="cnc-review-from">{from}</td>
                  <td class="cnc-review-to">{to}</td>
                </tr>
              </tbody>
            </table>
            <p class="cnc-sub">
              The controller stores these immediately. They're read back afterwards to confirm.
            </p>
            <div class="cnc-row">
              <button type="button" class="cnc-btn" phx-click="back">Back</button>
              <button
                type="button"
                class="cnc-btn cnc-btn--primary"
                phx-click="write"
                disabled={@machine.state not in [:idle, :alarm]}
              >
                Write {pluralize(length(changes(assigns)), "setting")}
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_settings(socket) do
    settings = Machine.settings()
    assign(socket, settings: settings, grouped: Settings.grouped(settings)) |> bump_form()
  end

  # A new form id re-renders inputs with the controller's values.
  defp bump_form(socket), do: assign(socket, form_rev: (socket.assigns[:form_rev] || 0) + 1)

  defp changes(%{settings: settings, edits: edits}), do: Settings.diff(settings, edits)

  defp result_class(:pending), do: "is-pending"
  defp result_class(:ok), do: "is-ok"
  defp result_class(_), do: "is-error"

  defp result_text(:pending), do: "writing"
  defp result_text(:ok), do: "saved"
  defp result_text({:error, code}), do: "refused (error #{code})"

  defp pluralize(1, word), do: "1 #{word}"
  defp pluralize(n, word), do: "#{n} #{word}s"

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
