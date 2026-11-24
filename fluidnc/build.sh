#!/usr/bin/env bash
# Build FluidNC to run natively on this computer: the dev controller.
#
# The real FluidNC firmware (motion planner, Grbl protocol, config parser)
# compiled as a Mac/Linux program, with step pulses counted instead of sent
# to pins. Stock FluidNC, pinned to a tested commit.
#
#   fluidnc/build.sh          # -> .fluidnc/bin/fluidnc
#
# Needs git and python3; installs PlatformIO into .fluidnc/venv (not system
# wide). First build ~2 min (toolchain + libraries), rebuilds ~30 s.
set -euo pipefail

COMMIT=97dfddceb95b499b06c0ad87297ea0b4f9cec662
PLATFORMIO=6.2.0

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/.fluidnc"
src="$work/src"

case "$(uname -s)" in
  Darwin) env=macos ;;
  Linux) env=linux ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

mkdir -p "$work/bin"

if [ ! -d "$src/.git" ]; then
  git clone --quiet https://github.com/bdring/FluidNC.git "$src"
fi
git -C "$src" fetch --quiet origin "$COMMIT" 2>/dev/null || git -C "$src" fetch --quiet origin
git -C "$src" checkout --quiet --force "$COMMIT"
git -C "$src" clean --quiet -fd -e .pio

if [ ! -x "$work/venv/bin/pio" ]; then
  python3 -m venv "$work/venv"
  "$work/venv/bin/pip" install --quiet "platformio==$PLATFORMIO"
fi

(cd "$src" && "$work/venv/bin/pio" run -e "$env")
cp "$src/.pio/build/$env/program" "$work/bin/fluidnc"
echo "built $work/bin/fluidnc (FluidNC ${COMMIT:0:7}, $env)"
