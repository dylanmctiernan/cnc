#!/usr/bin/env bash
# Build the FluidNC sim: FluidNC compiled to run natively on this computer,
# the dev controller (CNC.Transport.FluidNCSim, config fluidnc/sim.yaml).
#
# The real FluidNC firmware (motion planner, Grbl protocol, config parser)
# as a Mac/Linux program, with step pulses counted instead of sent to pins.
#
#   fluidnc/build.sh          # -> .fluidnc/bin/fluidnc
#
# Needs git and python3; installs PlatformIO into .fluidnc/venv (not system
# wide). First build ~2 min (toolchain + libraries), rebuilds ~30 s.
set -euo pipefail
. "$(dirname "$0")/common.sh"

case "$(uname -s)" in
  Darwin) env=macos ;;
  Linux) env=linux ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

fluidnc_checkout
(cd "$src" && "$pio" run -e "$env")
# Replace, don't overwrite: macOS ties a program's code signature to the file
# it first ran from, and kills a binary rewritten in place (exit 137).
rm -f "$work/bin/fluidnc"
cp "$src/.pio/build/$env/program" "$work/bin/fluidnc"
echo "built $work/bin/fluidnc (FluidNC ${COMMIT:0:7}, $env)"
