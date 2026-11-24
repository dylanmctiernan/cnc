defmodule CNCWeb.PinHTML do
  use CNCWeb, :html

  attr :error, :string, default: nil

  # A 4-digit pad in the style of the machine's readout. The real field is a
  # single numeric input laid over the cells (so phone keyboards, paste and
  # password managers work); assets/js/pin_pad.js mirrors it into the cells,
  # wires the keypad and submits on the fourth digit.
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
          <span :for={_ <- 1..4} class="cnc-pin-cell" aria-hidden="true"></span>
        </div>

        <p :if={@error} id="pin-error" class="cnc-pin-error" role="alert">{@error}</p>

        <div class="cnc-pin-pad" aria-hidden="true">
          <button :for={d <- ~w(1 2 3 4 5 6 7 8 9)} type="button" tabindex="-1" data-digit={d}>
            {d}
          </button>
          <button type="button" tabindex="-1" data-back class="cnc-pin-back">⌫</button>
          <button type="button" tabindex="-1" data-digit="0">0</button>
        </div>
      </form>
    </main>
    """
  end
end
