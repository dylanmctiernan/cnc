defmodule CNCWeb.PinHTML do
  use CNCWeb, :html

  def new(assigns) do
    ~H"""
    <main class="cnc-pin">
      <form action={~p"/pin"} method="post" class="cnc-pin-form">
        <h1 class="cnc-title">CNC</h1>
        <p>Enter the PIN to use the machine from this device.</p>
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <label for="pin" class="cnc-h">PIN</label>
        <input
          id="pin"
          name="pin"
          type="password"
          inputmode="numeric"
          autocomplete="current-password"
          autofocus
          required
          aria-describedby={@error && "pin-error"}
        />
        <p :if={@error} id="pin-error" class="cnc-pin-error" role="alert">{@error}</p>
        <button type="submit" class="cnc-btn cnc-btn--primary">Continue</button>
      </form>
    </main>
    """
  end
end
