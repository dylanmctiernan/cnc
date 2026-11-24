defmodule CNCWeb.Pin do
  @moduledoc """
  Optional shared-PIN access for the UI (`config :cnc, :access_pin`).

  When a PIN is configured, every browser enters it once. The session keeps
  a hash of the PIN, so changing the PIN logs every device out. Checked by
  the plug for normal requests and by `on_mount` for LiveView connections.

  Lock screen (`revoke/1`) forgets it for this browser and disconnects the
  browser's other open pages (each grant gets its own `live_socket_id`), so
  every tab goes back to the PIN.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  @session_key "pin_ok"

  def configured, do: Application.get_env(:cnc, :access_pin)

  @doc "True if the PIN matches the configured one (constant-time)."
  def valid?(given) when is_binary(given),
    do: configured() != nil and Plug.Crypto.secure_compare(given, configured())

  def valid?(_), do: false

  def grant(conn) do
    conn
    |> configure_session(renew: true)
    |> put_session(@session_key, token())
    |> put_session(:live_socket_id, "pin:" <> Base.url_encode64(:crypto.strong_rand_bytes(12)))
  end

  @doc "Lock screen: this browser needs the PIN again, in every open page."
  def revoke(conn) do
    if id = get_session(conn, :live_socket_id),
      do: CNCWeb.Endpoint.broadcast(id, "disconnect", %{})

    configure_session(conn, drop: true)
  end

  def granted?(session) do
    case configured() do
      nil ->
        true

      _pin ->
        is_binary(session[@session_key]) and
          Plug.Crypto.secure_compare(session[@session_key], token())
    end
  end

  defp token, do: :crypto.hash(:sha256, "cnc-pin:" <> configured()) |> Base.encode64()

  ## Plug

  def init(opts), do: opts

  def call(%{request_path: "/pin"} = conn, _opts), do: conn

  def call(conn, _opts) do
    if granted?(get_session(conn)), do: conn, else: conn |> redirect(to: "/pin") |> halt()
  end

  ## LiveView

  def on_mount(:default, _params, session, socket) do
    if granted?(session),
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/pin")}
  end
end
