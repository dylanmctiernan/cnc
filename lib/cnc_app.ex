defmodule CNCApp do
  @moduledoc """
  OTP application: supervision tree and config wiring only.

  Its own top-level boundary (a sibling of `CNC` and `CNCWeb`), so the
  wiring layer is the only place allowed to know about both.
  """
  use Boundary, deps: [CNC, CNCWeb]
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CNCWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:cnc, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: CNC.PubSub},
      CNC.Machine,
      CNC.Program,
      # After Machine: connects it to the active controller
      CNC.Controllers,
      CNCWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: CNCApp.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CNCWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
