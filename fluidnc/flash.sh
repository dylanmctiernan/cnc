#!/usr/bin/env bash
# Flash a classic ESP32 board with FluidNC and a config, over USB.
#
#   fluidnc/flash.sh /dev/cu.usbserial-0001                # esp32_bench.yaml
#   fluidnc/flash.sh /dev/cu.usbserial-0001 fluidnc/other.yaml
#   fluidnc/flash.sh --build-only                          # no board needed
#
# Same pinned FluidNC commit as the sim, "noradio" build: serial only, so
# the board never starts a Wi-Fi access point. Writes two things:
#   1. the firmware
#   2. the board's little file system, holding the config as config.yaml
# Find the port with `mix cnc.ports`. Close anything holding the port (the
# dev server with CNC_TRANSPORT=uart) first. If the upload can't connect,
# hold the board's BOOT button while it says "Connecting...".
set -euo pipefail
. "$(dirname "$0")/common.sh"

env=noradio
port="${1:-}"
config="${2:-$root/fluidnc/esp32_bench.yaml}"
[ -n "$port" ] || { echo "usage: $0 <serial port> [config.yaml] | --build-only" >&2; exit 1; }
[ -f "$config" ] || { echo "no such config: $config" >&2; exit 1; }

fluidnc_checkout
cp "$config" "$src/FluidNC/data/config.yaml"

cd "$src"
if [ "$port" = "--build-only" ]; then
  "$pio" run -e "$env"
  "$pio" run -e "$env" -t buildfs
  echo "built firmware and file system ($env); not flashed"
else
  "$pio" run -e "$env" -t upload --upload-port "$port"
  "$pio" run -e "$env" -t uploadfs --upload-port "$port"
  echo "flashed FluidNC ${COMMIT:0:7} ($env) with $(basename "$config") to $port"
fi
