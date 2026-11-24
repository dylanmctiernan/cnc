# CNC Host

Elixir/Phoenix LiveView host for a home-built CNC router (FluidNC controller).
See [PLAN.md](PLAN.md) for the full Phase 1 plan.

## Boundaries

Enforced at compile time by [Boundary](https://hexdocs.pm/boundary); a violation fails
`mix compile --warnings-as-errors`.

```
CNCApp  (supervision + wiring)          deps: CNC, CNCWeb
├── CNCWeb  (LiveView UI)               deps: CNC          exports: Endpoint, Telemetry
└── CNC  (domain)                       deps: —            exports: Machine
    ├── CNC.Machine  state + jogging    deps: Grbl, Motion
    ├── CNC.Motion   transport port     deps: Grbl
    └── CNC.Grbl     pure protocol      deps: —
```

The web layer can only reach `CNC.Machine`; protocol and transport stay private to the domain.

## Dev

```sh
mise install        # Erlang/Elixir from .mise.toml
mix setup
mix phx.server      # http://localhost:4000
mix test            # grblHAL sim tests excluded; run with --only grblhal_sim
```
