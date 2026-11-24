"""FluidNC sim behind a virtual serial port, like a board on a USB cable.

    python3 fluidnc_serial.py <fluidnc executable> <run dir>

Makes two pseudo-terminal pairs and relays bytes between their master ends.
FluidNC runs with one slave as its terminal (stdin/stdout); the other
slave's device path is printed on the first line of stdout, for
CNC.Transport.UART to open. Exits, stopping FluidNC, when stdin closes.
"""
import os, pty, select, signal, subprocess, sys, tty

exe, run_dir = sys.argv[1], sys.argv[2]

host_master, host_slave = pty.openpty()  # the end our UART adapter opens
board_master, board_slave = pty.openpty()  # FluidNC's terminal
tty.setraw(host_slave)
tty.setraw(board_slave)

fluidnc = subprocess.Popen(
    [exe], cwd=run_dir, stdin=board_slave, stdout=board_slave, stderr=board_slave,
    start_new_session=True,
)
os.close(board_slave)

sys.stdout.buffer.write(os.ttyname(host_slave).encode() + b"\n")
sys.stdout.buffer.flush()

stdin = sys.stdin.buffer.fileno()
try:
    while fluidnc.poll() is None:
        ready, _, _ = select.select([host_master, board_master, stdin], [], [], 0.5)
        if stdin in ready and not os.read(stdin, 4096):
            break
        for src, dst in ((host_master, board_master), (board_master, host_master)):
            if src in ready:
                try:
                    data = os.read(src, 4096)
                except OSError:
                    continue
                os.write(dst, data)
finally:
    if fluidnc.poll() is None:
        os.killpg(fluidnc.pid, signal.SIGTERM)
        fluidnc.wait(timeout=2)
