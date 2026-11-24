defmodule CNCWeb.PageController do
  use CNCWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
