# Bench: ESP32 + FluidNC

First session with real hardware: the ELEGOO ESP32 (30-pin, ESP-WROOM-32,
CP2102) on a breadboard, no motors. Buttons stand in for limit switches and
two wires for the probe. Everything from the app down is what the machine
will use; only the motors and drivers are missing.

Record what you find in `docs/bench-log.md`.

## 1. Plug in

1. ESP32 into the Mac with the USB-C data cable. The red power LED should
   light. If it doesn't, use the USB-A cable through the adapter (some
   boards lack the resistors USB-C to USB-C needs).
2. Find its port:

   ```sh
   mix cnc.ports
   ```

   Expect something like `/dev/cu.usbserial-0001` (Silicon Labs CP2102). If
   nothing appears, install the Silicon Labs CP210x driver and replug.

## 2. Flash FluidNC and the config

```sh
mix cnc.fluidnc.flash /dev/cu.usbserial-0001
```

This builds FluidNC from the same pinned commit as the FluidNC sim (the
`noradio` build: serial only, no Wi-Fi access point), writes it, then writes
the ESP32 DevKit board's default config (`CNC.Boards`: this machine with the
bench pins) to the board as `config.yaml`. The first run
downloads the ESP32 toolchain (a few minutes).

If it stops at `Connecting....`, hold the board's **BOOT** button until the
upload starts. Nothing else should have the port open (stop the dev server
if it's on `uart`).

After this the board's own config is the one that counts: change it from the
app's Settings (coming next) rather than by reflashing.

## 3. Wire the buttons

Pins come from the ESP32 DevKit board in `CNC.Boards` (`lib/cnc/boards.ex`). Use the labels printed on the board; on
30-pin boards GPIO 16 and 17 are often labelled **RX2** and **TX2**.

| Function | GPIO | Wire |
|---|---|---|
| X limit (home) | 16 (RX2) | button between pin and GND |
| Y limit (home) | 17 (TX2) | button between pin and GND |
| Z limit (home) | 4 | button between pin and GND |
| Probe | 18 | one loose wire on the pin, one on GND: touch them together |

- Put a jumper from a **GND** pin to the breadboard's blue (−) rail and take
  every button's ground from the rail.
- The 4-leg tactile buttons connect their legs in pairs. Use two **diagonal**
  legs so you're sure to cross the switch.
- No resistors needed: the config turns on the ESP32's internal pull-ups
  (`:pu`) and reads a pressed button as active (`:low`).
- Never connect anything to 5 V or VIN; the pins are 3.3 V only.

Optional LEDs, to see motion: a direction pin → 330 Ω → LED long leg, short
leg → GND. Direction pins are X 26, Y 14, Z 32; the LED lights for one
direction and goes out for the other. (Step pins 25, 27, 33 pulse too fast to
see more than a faint glow.)

## 4. Run the app against the board

```sh
CNC_LINK=uart CNC_UART=/dev/cu.usbserial-0001 mix phx.server
```

The link label should read `UART connected`, the firmware `FluidNC v4.1.1`,
and the screen Locked. Open **Menu → Console** for the raw traffic (tick
**status polls** when you need the `<...>` reports).

## 5. Checks

Each answers something we couldn't learn from the sims. Note the result.

1. **Boot messages.** In the console's first lines: any `[MSG:ERR` is a
   config problem. Expect none.
2. **Does opening the port reset the board?** (PLAN §10) Unlock, jog X to
   about 50, then stop and restart the dev server. After it reconnects: X
   back at 0 means opening the port reset the board; X still at 50 means it
   didn't.
3. **Travel from the controller.** The facts panel shows travel 1250 x
   1250 x 100 (FluidNC's `$130`–`$132`), and no travel warning. (The sim
   already showed FluidNC reports these; this confirms it on the board.)
4. **Homing.** Click **Home**. Z homes first (cycle 1), moving up:
   - press and release the **Z** button: it backs off 2 mm,
   - then approaches slowly: press it again; it backs off and Z is done.
   Then X and Y together (cycle 2): do the same with both buttons.
   Expect Ready at exactly X 0, Y 0, Z 0: FluidNC sets the position after
   the final back-off, so the switches sit 2 mm outside travel. Then jog
   +X/+Y and −Z: positions should run 0..1250 and 0..−100. That answers
   PLAN §10's "homing leaves machine coordinates 0..travel".
   If you don't press a button in time, homing fails with `ALARM:9`: Unlock
   or Home again.
5. **Soft limits.** After homing, hold X− into the edge: the app slides to 0
   and stops, no error. Then in the console type `G0 X-10`: FluidNC should
   refuse it (note whether it's an `error:` or an `ALARM:`).
6. **Hard limit.** While jogging, press a limit button: expect `ALARM:1`,
   the screen Locked, motion stopped. Unlock to continue.
7. **Queued lines after an alarm.** (PLAN §10) Same as 6, but watch the
   console: after the alarm, does the app go on working (Unlock, jog)
   without waiting for `ok`s that never come? Note any `ok`s that arrive
   after the `ALARM:1` line.
8. **Probe.** With status polls showing, touch the probe wires together:
   the report gains `Pn:P` while they touch.
9. **Jog cancel.** (The sim can't test `0x85`.) Hold a jog at fast for a
   second and release: it should stop within a few mm. Then tap an arrow
   key as briefly as you can, ten times: each tap should move only a
   little (well under 10 mm at fast). The console shows a second `0x85`
   when a line ran past the first cancel; that's Machine cancelling again.
10. **Unplug mid-jog.** Hold a jog and pull the USB cable: expect Not
   connected, and on replugging, reconnect and Locked.
11. **Configuration over USB.** (The sims don't use XModem.) Open the
   controller's Configuration page: the wiring should match the ESP32
   DevKit pin map. Change X's max rate, Save, and check the file. Then
   **Write board default** as `bench-default`: this goes by XModem, so the
   state shows Uploading for a moment and the file appears (same size as
   the generated config). View it, then Delete it. Restore the version
   kept before the save. Note any transfer that fails, with the console.

## 6. Afterwards

Add a dated entry to `docs/bench-log.md` with the answers, and update PLAN
§10 (strike the answered questions). Anything surprising goes in as a test
against the FluidNC sim if the sim can show it.
