defmodule CNCWeb.PinHTML do
  use CNCWeb, :html

  attr :error, :string, default: nil

  # Four cells in the style of the machine's readout over a single native
  # numeric input (inputmode="numeric": the phone's own number pad, paste and
  # password managers work). No on-screen keypad: on iOS it fought the native
  # keyboard. assets/js/pin_pad.js mirrors the input into the cells and
  # submits on the fourth digit.
  def new(assigns) do
    ~H"""
    <main class="cnc-pin">
      <form
        id="pin-form"
        action={~p"/pin"}
        method="post"
        class={["cnc-pin-form", @error && "is-error"]}
      >
        <h1 class="cnc-pin-title">CNC</h1>
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />

        <div class="cnc-pin-cells">
          <label for="pin" class="sr-only">PIN</label>
          <input
            id="pin"
            name="pin"
            type="password"
            inputmode="numeric"
            pattern="[0-9]{4}"
            maxlength="4"
            autocomplete="current-password"
            autofocus
            required
            aria-describedby={@error && "pin-error"}
          />
          <%!-- The first cell starts marked, before any script runs --%>
          <span
            :for={i <- 1..4}
            class={["cnc-pin-cell", i == 1 && "is-active"]}
            aria-hidden="true"
          >
          </span>
        </div>

        <p :if={@error} id="pin-error" class="cnc-pin-error" role="alert">{@error}</p>
      </form>
    </main>
    """
  end
end
