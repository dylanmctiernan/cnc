defmodule CNCWeb.PinController do
  use CNCWeb, :controller

  alias CNCWeb.Pin

  def new(conn, _params) do
    if Pin.configured(), do: render(conn, :new, error: nil), else: redirect(conn, to: ~p"/")
  end

  def create(conn, %{"pin" => pin}) do
    if Pin.valid?(pin) do
      conn |> Pin.grant() |> redirect(to: ~p"/")
    else
      # Slow down guessing.
      Process.sleep(1000)
      conn |> put_status(:unauthorized) |> render(:new, error: "Wrong PIN")
    end
  end
end
