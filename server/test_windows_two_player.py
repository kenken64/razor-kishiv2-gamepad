"""Exercise the Windows release through TCP and the OS XInput API (requires ViGEmBus)."""
import argparse
import ctypes
from contextlib import ExitStack
import re
import socket
import struct
import subprocess
import threading
import time


class Phone:
    def __init__(self, pin, buttons, trigger):
        self.socket = socket.create_connection(("127.0.0.1", 26760), timeout=5)
        try:
            self.socket.sendall(b"KSH1" + pin)
            with self.socket.makefile("rb", buffering=0) as reply:
                assert b"".join(reply.read(1) for _ in range(3)) == b"OKR"
        except BaseException:
            self.socket.close()
            raise
        self.report = struct.pack(">HBBhhhh", buttons, trigger, 0, 0, 0, 0, 0)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.stream)
        self.thread.start()

    def stream(self):
        while not self.stop.wait(0.025):
            self.socket.sendall(self.report)

    def close(self):
        self.stop.set()
        self.thread.join()
        self.socket.close()


def xinput_states():
    read = ctypes.windll.xinput1_4.XInputGetState
    states = {}
    for index in range(4):
        buf = ctypes.create_string_buffer(16)
        if read(index, buf) == 0:
            states[index] = struct.unpack_from("<HB", buf.raw, 4)
    return states


def wait_for(check):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        states = xinput_states()
        if check(states):
            return states
        time.sleep(0.025)
    raise AssertionError(f"Unexpected Windows XInput states: {states}")


def main(exe):
    with ExitStack() as cleanup:
        receiver = subprocess.Popen([exe], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
        cleanup.callback(receiver.wait)
        cleanup.callback(receiver.kill)
        line = receiver.stdout.readline()
        match = re.search(rb"Pairing code (\d{6})", line)
        assert match, line
        pin = match[1]
        a, b = (0x1000, 61), (0x2000, 157)
        first = Phone(pin, *a)
        cleanup.callback(first.close)
        second = Phone(pin, *b)
        cleanup.callback(second.close)
        states = wait_for(lambda s: a in s.values() and b in s.values())
        p1 = next(i for i, state in states.items() if state == a)
        p2 = next(i for i, state in states.items() if state == b)
        assert p1 != p2
        with socket.create_connection(("127.0.0.1", 26760), timeout=3) as extra:
            extra.sendall(b"KSH1" + pin)
            with extra.makefile("rb") as reply:
                assert reply.read(4) == b"BUSY"
        second.close()
        wait_for(lambda s: s.get(p1) == a and p2 not in s)
        replacement = Phone(pin, *b)
        cleanup.callback(replacement.close)
        wait_for(lambda s: s.get(p1) == a and b in s.values())
        first.close()
        wait_for(lambda s: s.get(p1) == (0, 0) and b in s.values())
        print(f"PASS: XInput slots {p1} and {p2}, independent reports, capacity, disconnect and rejoin")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receiver")
    main(parser.parse_args().receiver)
