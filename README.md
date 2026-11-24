# CNC Host

Elixir/Phoenix LiveView host for a home-built CNC router (FluidNC controller).
See [PLAN.md](PLAN.md) for the full Phase 1 plan.

## Boundaries

Enforced at compile time by [Boundary](https://hexdocs.pm/boundary); a violation fails
`mix compile --warnings-as-errors`.

```
CNCApp  (supervision + wiring)            deps: CNC, CNCWeb
├── CNCWeb  (LiveView UI)                 deps: CNC          exports: Endpoint, Telemetry
└── CNC  (domain)                         deps: —            exports: Machine
    ├── CNC.Machine    state + jogging    deps: Grbl, Transport
    ├── CNC.Transport  link to controller deps: Grbl         exports: Sim
    └── CNC.Grbl       pure protocol      deps: —
```

The web layer can only reach `CNC.Machine`; protocol and transport stay private to the domain.

## Dev

```sh
mise install        # Erlang/Elixir from .mise.toml
mix setup
mix phx.server      # http://localhost:4000, built-in simulator
mix test
```

### Against the real board (FluidNC over USB)

```sh
mix cnc.ports                                          # find the board, e.g. /dev/cu.usbserial-0001
CNC_TRANSPORT=uart CNC_UART=/dev/cu.usbserial-0001 mix phx.server
```

Opening the port may reset the board; the machine then shows Locked as after
any controller restart. The serial adapter is tested against a virtual serial
port (`test/support/pty_bridge.py`), not yet against hardware.

FluidNC can also be reached over Wi-Fi (telnet, port 23):

```sh
CNC_TRANSPORT=tcp CNC_TCP=fluidnc.local mix phx.server  # or <ip>:<port>
```

### From another device on your network

```sh
CNC_LAN=1 CNC_PIN=1234 mix phx.server     # 4 digits; then open http://<this-mac's-ip>:4000
```

Dev only. `CNC_LAN=1` refuses to start without a PIN; each browser enters it
once. Changing the PIN logs every device out. `CNC_PIN` alone (without
`CNC_LAN`) protects a local-only server too.
