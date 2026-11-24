# Shared by build.sh and flash.sh: the pinned FluidNC checkout and PlatformIO.
# Stock FluidNC, pinned to the commit the sim and the board both run.

COMMIT=97dfddceb95b499b06c0ad87297ea0b4f9cec662
PLATFORMIO=6.2.0

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/.fluidnc"
src="$work/src"
pio="$work/venv/bin/pio"

fluidnc_checkout() {
  mkdir -p "$work/bin"
  if [ ! -d "$src/.git" ]; then
    git clone --quiet https://github.com/bdring/FluidNC.git "$src"
  fi
  git -C "$src" fetch --quiet origin "$COMMIT" 2>/dev/null || git -C "$src" fetch --quiet origin
  git -C "$src" checkout --quiet --force "$COMMIT"
  git -C "$src" clean --quiet -fd -e .pio

  if [ ! -x "$pio" ]; then
    python3 -m venv "$work/venv"
    "$work/venv/bin/pip" install --quiet "platformio==$PLATFORMIO"
  fi
}
