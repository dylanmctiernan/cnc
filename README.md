# CNC

A web app for running a home-built CNC router from a computer or a phone.

You load a cutting file, check it fits, and watch it cut, with a big **Hold**
button always on screen. You can try all of it without a machine: it comes with
a simulator that runs the real controller software on your computer.

> This moves a real machine. It's a hobby project: keep a physical emergency
> stop within reach.

## Try it

You need [mise](https://mise.jdx.dev), which installs everything else for this
project. To install it:

```sh
curl https://mise.run | sh      # or on a Mac: brew install mise
```

Then turn it on in your terminal (once), and open a new terminal window:

```sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc     # Mac (zsh)
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc   # Linux (bash)
```

(If you installed it with Homebrew, use `mise activate` instead of
`~/.local/bin/mise activate`.) Check it works with `mise --version`.

Then:

```sh
git clone <this repo> cnc && cd cnc
mise run setup                  # once; the first time takes 10–20 minutes
mise run dev
```

Open **http://localhost:4000**, press **Unlock**, and jog around. To cut
something, open the **Auto** tab and drop in `test/fixtures/quick.nc`.

If setup stops while building Erlang, install a compiler first:

- **Mac:** `xcode-select --install`, then `brew install openssl@3 autoconf`
- **Linux / Raspberry Pi:** `sudo apt install build-essential autoconf libssl-dev libncurses-dev`

### On Windows

Use WSL, which runs Linux inside Windows (the simulator only builds on Mac and
Linux):

1. In PowerShell: `wsl --install`, then restart and open **Ubuntu** from the
   Start menu.
2. In Ubuntu, follow the steps above as on Linux (install mise, then the
   `apt install` line, then `mise run setup`).
3. Open **http://localhost:4000** in your Windows browser as usual.

For a real machine, the USB board has to be passed through to WSL with
[usbipd-win](https://learn.microsoft.com/windows/wsl/connect-usb). For the phone
pendant, turn on WSL's mirrored networking so your phone can reach it: add
`networkingMode=mirrored` under `[wsl2]` in `%UserProfile%\.wslconfig`, then run
`wsl --shutdown` and start Ubuntu again.

### On your phone

```sh
CNC_LAN=1 mise run dev
```

Then open `http://<your-computer>.local:4000/pendant` on a phone on the same
Wi-Fi. On an iPhone, **Share → Add to Home Screen** makes it an app.

There's no password: anyone on your network can use it. Keep it on a home
network you trust.

### With a real machine

The controller is an ESP32 board running FluidNC, plugged in by USB:

```sh
mix cnc.ports                                  # find the board
mix cnc.fluidnc.flash /dev/cu.usbserial-0001   # put FluidNC on it
```

Then choose it under **Controllers** in the app.

---

## Words used here

| Word | Means |
|---|---|
| **Controller** | The small computer on the machine that turns commands into motor steps. Here, an ESP32 board. |
| **FluidNC** | The software on the controller. |
| **G-code** | The cutting file: a list of moves, made by design software (CAM). |
| **Work zero** | The point on your piece that the file measures from, usually a corner of its top. |
| **Jog** | Moving the machine by hand. **Inc** moves it one fixed step per press. |
| **Hold / Resume** | Pause all motion now, keeping its place / carry on. |
| **Abort** | End the job. The machine comes back **Locked** until you Unlock it. |
| **Stock** | The piece of material you're cutting. |
| **Rapids** | Fast moves in the air between cuts. |
| **Dry run** | Running the file with the bit lifted clear, to watch the path safely. |
| **Pendant** | A handheld remote for the machine: here, your phone. |
| **Sim** | The simulator: the real FluidNC software running on your computer, with no motors. |

## How it's built

- **Elixir and Phoenix** run the app. Each screen is a live page that updates as
  the machine moves, without reloading.
- **One part talks to the machine.** Every button, on every screen and phone,
  goes through it, and it only allows what's safe in the machine's current state
  (you can't jog while a job runs, for example). The allowed moves are written
  down in one table, and a test checks the real code against it with thousands
  of random button sequences.
- **three.js** draws the 3D view.
- **The tests** run against a fake controller, and against the real FluidNC
  software when the sim is built.

| Folder | What's in it |
|---|---|
| `lib/cnc/` | The machine: talking to the controller, running jobs, reading G-code |
| `lib/cnc_web/` | The screens: the workstation and the phone pendant |
| `lib/cnc_app/` | Your saved settings: the stock, the bit, preferences |
| `priv/fluidnc/` | The machine's FluidNC settings (size, speeds) |
| `test/` | The tests, and sample cutting files in `test/fixtures/` |

`mise run test` runs every test. `PLAN.md` has the longer story of how and why
it's built this way.

## License

GPL-3.0: you can use, change and share it, as long as changed versions you share stay open under the same license. See [LICENSE](LICENSE).
