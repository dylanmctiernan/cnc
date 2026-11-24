defmodule CNCWeb.Router do
  use CNCWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CNCWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug CNCWeb.Pin
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CNCWeb do
    pipe_through :browser

    get "/pin", PinController, :new
    post "/pin", PinController, :create

    live_session :machine, on_mount: CNCWeb.Pin do
      live "/", MachineLive
      live "/settings", SettingsLive
      live "/controllers", ControllersLive
      live "/controllers/:id/configuration", ConfigLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", CNCWeb do
  #   pipe_through :api
  # end

  # LiveDashboard in development only (dev_routes is set in config/dev.exs).
  if Application.compile_env(:cnc, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CNCWeb.Telemetry
    end
  end
end
