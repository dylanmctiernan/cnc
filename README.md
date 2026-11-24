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
    ├── CNC.Machine    state + jogging    deps: Grbl, Link
    ├── CNC.Link  link to controller deps: Grbl         exports: Sim
    └── CNC.Grbl       pure protocol      deps: —
```

The web layer can only reach `CNC.Machine`; protocol and link stay private to the domain.

## Dev

```sh
mise install        # Erlang/Elixir from .mise.toml
mix setup
mix cnc.fluidnc.build    # once: real FluidNC firmware, built to run on this Mac
mix phx.server      # http://localhost:4000
mix test
```

`mix phx.server` drives FluidNC running natively on this computer (the real
firmware with `priv/fluidnc/sim.yaml`; nothing physical moves). Without the
build it falls back to the fake sim (a simple imitation built into the app);
`CNC_LINK=fake` forces that. Tests use the fake sim; the `test/cnc/fluidnc_sim_*_test.exs` modules
runs against native FluidNC when it's built.

The FluidNC sim has no switches, so homing is off (`$22=0`): Unlock instead. Edits to
`priv/fluidnc/sim.yaml` apply when the app restarts (FluidNC reads it at start).

### Against the real board (FluidNC over USB)

Flash the bench ESP32 with FluidNC (same pinned commit as the sim) and
`priv/fluidnc/esp32_bench.yaml`: `mix cnc.fluidnc.flash /dev/cu.usbserial-0001`. The
first session is in `docs/bench-esp32.md`.

```sh
mix cnc.ports                                          # find the board, e.g. /dev/cu.usbserial-0001
CNC_LINK=uart CNC_UART=/dev/cu.usbserial-0001 mix phx.server
```

Opening the port may reset the board; the machine then shows Locked as after
any controller restart. The serial adapter is tested against a virtual serial
port (`test/support/pty_bridge.py`), not yet against hardware.

FluidNC can also be reached over Wi-Fi (telnet, port 23):

```sh
CNC_LINK=tcp CNC_TCP=fluidnc.local mix phx.server  # or <ip>:<port>
```

### From another device on your network

```sh
CNC_LAN=1 CNC_PIN=1234 mix phx.server     # 4 digits; then open http://<this-mac's-ip>:4000
```

Dev only. `CNC_LAN=1` refuses to start without a PIN; each browser enters it
once.

For a name instead of an IP address, announce one over mDNS (Bonjour) in a
second terminal (macOS; Ctrl-C withdraws it):

```sh
mix cnc.mdns.announce               # cnc-XXXX.local (XXXX: this computer's id)
mix cnc.mdns.announce --name shop   # or a name you choose: shop.local
```

XXXX is a short random id made once and kept in `.cnc/device-id`, so the name
is stable and two machines never share one. It's its own site to browsers,
so other apps on `localhost:4000` don't share its favicon, cookies or PIN
session. Stop using it once the Pi announces its own name. Changing the PIN logs every device out. `CNC_PIN` alone (without
`CNC_LAN`) protects a local-only server too.
