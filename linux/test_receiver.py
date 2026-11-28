"""Run: GDK_BACKEND=x11 xvfb-run -a /usr/bin/python3 linux/test_receiver.py"""
import json
import os
from pathlib import Path
import socket
import struct
import sys
import time
import unittest
import warnings

from receiver import GLib, Gdk, NEUTRAL, ReceiverWindow

ROOT = Path(__file__).resolve().parent.parent


def wait_for(predicate, timeout=12):
    deadline = time.monotonic() + timeout
    context = GLib.MainContext.default()
    while time.monotonic() < deadline:
        while context.pending():
            context.iteration(False)
        if predicate():
            return
        time.sleep(.01)
    raise AssertionError("Timed out waiting for desktop state")


class DesktopIntegration(unittest.TestCase):
    def setUp(self):
        warnings.filterwarnings("ignore", category=DeprecationWarning, module=r"gi\.events")
        self.callback_errors = []
        self.previous_hook = sys.excepthook
        sys.excepthook = lambda *error: self.callback_errors.append(error)
        self.window = ReceiverWindow(ROOT / "server/target/release/padrelay-receiver",
                                     autostart=False, monitor=True)
        self.phone = None

    def tearDown(self):
        if self.phone:
            self.phone.close()
        self.window.closing = True
        self.window.stop_receiver()
        self.window.destroy()
        sys.excepthook = self.previous_hook
        self.assertFalse(self.callback_errors, self.callback_errors)

    def pair(self):
        self.window.start_receiver()
        wait_for(lambda: self.window.pin is not None and self.window.qr_rows)
        self.phone = socket.create_connection(("127.0.0.1", 26760), timeout=2)
        self.phone.sendall(b"KSH1" + self.window.pin.encode("ascii"))
        handshake = bytearray()
        while len(handshake) < 3:
            handshake.extend(self.phone.recv(3 - len(handshake)))
        self.assertEqual(handshake, b"OKR")
        wait_for(lambda: self.window.status.get_text() == "Phone connected")

    def javascript(self, expression):
        result = []

        def done(web, task, data):
            result.append(json.loads(web.evaluate_javascript_finish(task).to_json(0)))

        self.window.web.evaluate_javascript(expression, -1, None, None, None, done, None)
        wait_for(lambda: bool(result))
        return result[0]

    def test_pair_input_stall_disconnect_restart_and_preview(self):
        self.pair()
        state = (0x1201, 128, 240, 16000, -8000, -12000, 22000)
        self.phone.sendall(struct.pack("!HBBhhhh", state[0] | 0x0800, *state[1:]))
        self.assertEqual(self.phone.recv(1), b"A")
        wait_for(lambda: self.window.state == state)
        self.assertTrue(self.window.buttons[4096].get_style_context().has_class("pressed"))
        self.assertAlmostEqual(self.window.triggers[1].get_fraction(), 240 / 255)
        wait_for(lambda: self.window.status.get_text() == "Waiting for input")
        self.assertEqual(self.window.state, NEUTRAL)
        self.phone.sendall(struct.pack("!HBBhhhh", *state))
        wait_for(lambda: self.window.state == state)
        self.phone.close()
        self.phone = None
        wait_for(lambda: self.window.status.get_text() == "Waiting for phone")
        self.assertEqual(self.window.state, NEUTRAL)
        wait_for(lambda: self.window.preview_ready, timeout=25)
        wait_for(lambda: self.javascript('document.querySelector("output").textContent') == "", timeout=25)
        self.assertEqual(self.javascript('document.querySelector("#models").options.length'), 6)
        self.assertGreater(self.javascript('document.querySelector("canvas").width'), 0)
        self.window.preview_toggle.set_active(False)
        self.assertFalse(self.window.web.get_visible())
        self.window.preview_toggle.set_active(True)
        self.assertLessEqual(self.window.get_allocated_height(), 800)
        screenshot = Gdk.pixbuf_get_from_window(self.window.get_window(), 0, 0,
                                                self.window.get_allocated_width(),
                                                self.window.get_allocated_height())
        screenshot.savev(str(ROOT / "linux/build/receiver-test.png"), "png", [], [])
        old_process = self.window.process
        self.window.stop_receiver()
        self.assertIsNotNone(old_process.poll())
        self.assertIsNone(self.window.pin)
        self.assertFalse(self.window.qr_button.get_sensitive())
        self.pair()

    def test_rejected_pair_and_busy_port(self):
        self.window.start_receiver()
        wait_for(lambda: self.window.pin is not None)
        self.phone = socket.create_connection(("127.0.0.1", 26760), timeout=2)
        self.phone.sendall(b"KSH1xxxxxx")
        self.assertEqual(self.phone.recv(1), b"")
        wait_for(lambda: "[PAIRING FAILED]" in self.window.log_buffer.get_text(
            self.window.log_buffer.get_start_iter(), self.window.log_buffer.get_end_iter(), False))
        self.assertEqual(self.window.status.get_text(), "Waiting for phone")
        self.window.stop_receiver()
        with socket.socket() as occupied:
            occupied.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            occupied.bind(("0.0.0.0", 26760))
            occupied.listen()
            self.window.start_receiver()
            wait_for(lambda: self.window.process is None)
            self.assertIsNone(self.window.pin)
            self.assertEqual(self.window.status.get_text(), "Could not run receiver")

    @unittest.skipUnless(os.access("/dev/uinput", os.R_OK | os.W_OK), "uinput access required")
    def test_gamepad_mode_creates_and_removes_kernel_device(self):
        self.pair()
        previous = self.window.process
        self.window.mode.set_active_id("gamepad")
        self.assertIsNotNone(previous.poll())
        wait_for(lambda: self.window.pin is not None)

        def devices():
            return [p for p in Path("/sys/class/input").glob("input*/name")
                    if p.read_text().strip() == "PadRelay Gamepad"]

        wait_for(lambda: len(devices()) == 1)
        self.window.stop_receiver()
        wait_for(lambda: not devices())


if __name__ == "__main__":
    unittest.main(verbosity=2)
