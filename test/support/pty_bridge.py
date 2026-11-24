"""Virtual serial port for tests.

Opens a pseudo-terminal pair, prints the device path of one end on the first
line of stdout, then relays bytes: stdin -> pty (what the device "sends") and
pty -> stdout (what was written to the device). Exits when stdin closes.
"""
import os, pty, select, sys, tty

master, slave = pty.openpty()
tty.setraw(slave)
sys.stdout.buffer.write(os.ttyname(slave).encode() + b"\n")
sys.stdout.buffer.flush()

stdin = sys.stdin.buffer.fileno()
stdout = sys.stdout.buffer.fileno()
while True:
    ready, _, _ = select.select([master, stdin], [], [])
    if stdin in ready:
        data = os.read(stdin, 4096)
        if not data:
            break
        os.write(master, data)
    if master in ready:
        try:
            data = os.read(master, 4096)
        except OSError:
            continue
        os.write(stdout, data)
