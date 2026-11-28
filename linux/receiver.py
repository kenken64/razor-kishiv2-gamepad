#!/usr/bin/python3
"""GTK desktop frontend for the existing Rust receiver and shared 3D preview."""
import argparse
import base64
import json
import math
import os
from pathlib import Path
import re
import subprocess
import threading

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")
gi.require_foreign("cairo")
from gi.repository import Gdk, GLib, Gtk, WebKit2

HERE = Path(__file__).resolve().parent
BUTTONS = [("↑", 1), ("↓", 2), ("←", 4), ("→", 8),
           ("A", 4096), ("B", 8192), ("X", 16384), ("Y", 32768),
           ("LB", 256), ("RB", 512), ("LS", 64), ("RS", 128),
           ("Back", 32), ("Start", 16), ("Guide", 1024)]
NEUTRAL = (0, 0, 0, 0, 0, 0, 0)


def local_addresses():
    """Prefer physical LAN interfaces over VPN, bridge and container addresses."""
    try:
        result = subprocess.run(["ip", "-j", "-4", "addr", "show", "up"],
                                capture_output=True, text=True, check=True, timeout=3)
        addresses = []
        for interface in json.loads(result.stdout):
            name = interface["ifname"]
            if name == "lo":
                continue
            priority = 0 if name.startswith(("en", "eth", "wl")) else 1
            for address in interface.get("addr_info", []):
                if address.get("scope") == "global":
                    addresses.append((priority, address["local"], name))
        return [(ip, name) for _, ip, name in sorted(addresses)]
    except (OSError, ValueError, subprocess.SubprocessError):
        return []


def label(text, css=None):
    widget = Gtk.Label(label=text, xalign=0)
    if css:
        widget.get_style_context().add_class(css)
    return widget


class Stick(Gtk.DrawingArea):
    def __init__(self, title):
        super().__init__()
        self.title = title
        self.x = self.y = 0
        self.set_size_request(125, 135)
        self.connect("draw", self.draw)

    def draw(self, widget, cr):
        width, height = self.get_allocated_width(), self.get_allocated_height()
        cx, cy, radius = width / 2, height / 2 - 10, 43
        cr.set_source_rgb(.18, .25, .31)
        cr.arc(cx, cy, radius, 0, 2 * math.pi)
        cr.fill()
        cr.set_source_rgb(.34, .43, .48)
        cr.set_line_width(1)
        cr.move_to(cx - radius, cy)
        cr.line_to(cx + radius, cy)
        cr.move_to(cx, cy - radius)
        cr.line_to(cx, cy + radius)
        cr.stroke()
        cr.set_source_rgb(.34, .88, .74)
        cr.arc(cx + self.x / 32768 * 32, cy - self.y / 32768 * 32, 11, 0, 2 * math.pi)
        cr.fill()
        cr.set_source_rgb(.8, .87, .9)
        cr.set_font_size(12)
        cr.move_to(10, height - 8)
        cr.show_text(f"{self.title}  {self.x}, {self.y}")


class ReceiverWindow(Gtk.Window):
    def __init__(self, binary, autostart=True, monitor=False):
        super().__init__(title="PadRelay")
        self.binary = str(binary)
        self.process = None
        self.generation = 0
        self.closing = False
        self.state = NEUTRAL
        self.pin = None
        self.qr_rows = []
        self.preview_ready = False
        self.models = {}
        self.set_default_size(1120, 790)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("delete-event", self.close)
        Gtk.Settings.get_default().set_property("gtk-application-prefer-dark-theme", True)
        css = Gtk.CssProvider()
        css.load_from_data(b"""
            window { background: #15212d; color: #e5edf1; }
            .title { font-size: 26px; font-weight: bold; }
            .muted { color: #a5b9c6; }
            .code { font-size: 38px; font-weight: bold; color: #66dfbd; }
            .card { background: #1d2d3c; border-radius: 12px; padding: 16px; }
            .section { font-size: 17px; font-weight: bold; }
            .pad { background: #2d4050; border-radius: 7px; padding: 8px; }
            .pressed { background: #5fdfb8; color: #102b24; }
            button { padding: 7px 12px; }
            textview text { background: #111c26; color: #b6c9d6; }
        """)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14, margin=18)
        self.add(root)
        header = Gtk.Box(spacing=12)
        header.pack_start(label("PadRelay", "title"), True, True, 0)
        self.status = label("Stopped", "muted")
        header.pack_start(self.status, False, False, 0)
        self.preview_toggle = Gtk.CheckButton(label="Character preview")
        self.preview_toggle.set_active(True)
        header.pack_start(self.preview_toggle, False, False, 0)
        self.start_button = Gtk.Button(label="Start receiver")
        self.start_button.connect("clicked", self.toggle_receiver)
        header.pack_start(self.start_button, False, False, 0)
        root.pack_start(header, False, False, 0)

        body = Gtk.Box(spacing=16)
        root.pack_start(body, True, True, 0)
        sidebar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        sidebar.set_size_request(335, -1)
        sidebar_scroll = Gtk.ScrolledWindow()
        sidebar_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sidebar_scroll.add(sidebar)
        body.pack_start(sidebar_scroll, False, False, 0)
        pairing = self.card(sidebar, "Pair your phone")
        self.code_label = label("— — — — — —", "code")
        self.code_label.set_selectable(True)
        pairing.pack_start(self.code_label, False, False, 0)
        self.address = Gtk.ComboBoxText()
        addresses = local_addresses() or [("127.0.0.1", "No LAN address")]
        for ip, interface in addresses:
            self.address.append(ip, f"{ip}  ·  {interface}")
        self.address.set_active(0)
        self.address.connect("changed", self.address_changed)
        pairing.pack_start(self.address, False, False, 0)
        pairing.pack_start(label("Same local network · TCP 26760", "muted"), False, False, 0)
        self.qr_button = Gtk.Button(label="Show pairing QR")
        self.qr_button.set_sensitive(False)
        self.qr_button.connect("clicked", self.show_qr)
        pairing.pack_start(self.qr_button, False, False, 0)

        receiver = self.card(sidebar, "Receiver")
        self.mode = Gtk.ComboBoxText()
        self.mode.append("gamepad", "Gamepad · send input to Linux games")
        self.mode.append("monitor", "Monitor · display input only")
        can_gamepad = os.access("/dev/uinput", os.R_OK | os.W_OK)
        self.mode.set_active_id("monitor" if monitor or not can_gamepad else "gamepad")
        self.mode.connect("changed", self.mode_changed)
        receiver.pack_start(self.mode, False, False, 0)
        self.mode_hint = label("")
        self.mode_hint.set_line_wrap(True)
        self.mode_hint.set_max_width_chars(36)
        receiver.pack_start(self.mode_hint, False, False, 0)
        access = Gtk.Button(label="Enable gamepad access…")
        access.connect("clicked", self.enable_gamepad)
        receiver.pack_start(access, False, False, 0)

        right_column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        body.pack_start(right_column, True, True, 0)
        inputs = self.card(right_column, "Live controller input")
        controls = Gtk.Box(spacing=12)
        inputs.pack_start(controls, False, False, 0)
        sticks = Gtk.Box(spacing=8)
        self.left, self.right = Stick("L"), Stick("R")
        sticks.pack_start(self.left, True, True, 0)
        sticks.pack_start(self.right, True, True, 0)
        controls.pack_start(sticks, False, False, 0)
        buttons_and_triggers = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        controls.pack_start(buttons_and_triggers, True, True, 0)
        self.triggers = []
        for name in ("LT", "RT"):
            bar = Gtk.ProgressBar(show_text=True)
            bar.set_text(f"{name}  0%")
            buttons_and_triggers.pack_start(bar, False, False, 0)
            self.triggers.append(bar)
        grid = Gtk.Grid(column_spacing=6, row_spacing=6, column_homogeneous=True)
        self.buttons = {}
        for i, (name, mask) in enumerate(BUTTONS):
            button = label(name, "pad")
            button.set_xalign(.5)
            self.buttons[mask] = button
            grid.attach(button, i % 5, i // 5, 1, 1)
        buttons_and_triggers.pack_start(grid, False, False, 0)

        manager = WebKit2.UserContentManager()
        manager.register_script_message_handler("characters")
        manager.connect("script-message-received::characters", self.preview_message)
        self.web = WebKit2.WebView.new_with_user_content_manager(manager)
        self.web.get_settings().set_enable_webgl(True)
        self.web.get_settings().set_enable_fullscreen(True)
        self.web.connect("enter-fullscreen", lambda *_: self.fullscreen())
        self.web.connect("leave-fullscreen", lambda *_: self.unfullscreen())
        self.web.connect("decide-policy", self.navigation_policy)
        self.web.set_size_request(480, 280)
        right_column.pack_start(self.web, True, True, 0)
        right_column.reorder_child(self.web, 0)
        self.web.load_uri((HERE / "build/preview/index.html").as_uri())
        self.preview_toggle.connect("toggled", self.toggle_preview)

        root.pack_start(label("Receiver activity", "section"), False, False, 0)
        self.log_view = Gtk.TextView(editable=False, cursor_visible=False, monospace=True,
                                     wrap_mode=Gtk.WrapMode.WORD_CHAR)
        self.log_buffer = self.log_view.get_buffer()
        scroll = Gtk.ScrolledWindow()
        scroll.set_size_request(-1, 110)
        scroll.add(self.log_view)
        root.pack_start(scroll, False, False, 0)
        self.update_mode_hint()
        self.show_all()
        if autostart:
            GLib.idle_add(self.start_receiver)

    @staticmethod
    def card(parent, title):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=9)
        box.get_style_context().add_class("card")
        box.pack_start(label(title, "section"), False, False, 0)
        parent.pack_start(box, False, False, 0)
        return box

    def log(self, line):
        self.log_buffer.insert(self.log_buffer.get_end_iter(), line + "\n")
        if self.log_buffer.get_line_count() > 250:
            self.log_buffer.delete(self.log_buffer.get_start_iter(),
                                   self.log_buffer.get_iter_at_line(50))
        self.log_view.scroll_to_iter(self.log_buffer.get_end_iter(), 0, False, 0, 0)

    def update_mode_hint(self):
        self.mode_hint.set_text(
            "Creates PadRelay Gamepad for Linux games."
            if self.mode.get_active_id() == "gamepad" else
            "Pairs and previews input. Enable gamepad access, then select Gamepad to play.")

    def start_receiver(self):
        if self.process is not None or self.closing:
            return False
        self.pin = None
        self.qr_rows = []
        self.code_label.set_text("— — — — — —")
        self.qr_button.set_sensitive(False)
        args = [self.binary, "--ui", "--qr-host", self.address.get_active_id()]
        if self.mode.get_active_id() == "monitor":
            args.append("--monitor")
        try:
            self.process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                            text=True, bufsize=1)
        except OSError as error:
            self.log(f"Cannot start receiver: {error}")
            self.status.set_text("Could not start")
            return False
        self.generation += 1
        generation, process = self.generation, self.process
        self.status.set_text("Starting…")
        self.start_button.set_label("Stop receiver")
        self.log(f"Starting {self.mode.get_active_id()} receiver")

        def read_output():
            for line in process.stdout:
                GLib.idle_add(self.on_line, generation, line.strip())
            process.stdout.close()
            GLib.idle_add(self.on_exit, generation, process.wait())

        threading.Thread(target=read_output, daemon=True).start()
        return False

    def stop_receiver(self):
        self.generation += 1  # Ignore queued callbacks from the previous process.
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.process = None
        self.pin = None
        self.qr_rows = []
        self.code_label.set_text("— — — — — —")
        self.qr_button.set_sensitive(False)
        self.start_button.set_label("Start receiver")
        self.status.set_text("Stopped")
        self.apply_state(NEUTRAL)

    def toggle_receiver(self, *_):
        if self.process:
            self.stop_receiver()
            self.log("Receiver stopped")
        else:
            self.start_receiver()

    def mode_changed(self, *_):
        self.update_mode_hint()
        if self.process:
            self.stop_receiver()
            self.start_receiver()

    def address_changed(self, *_):
        # Restart to regenerate the QR with the selected interface and a fresh code.
        if self.process:
            self.stop_receiver()
            self.start_receiver()

    def on_line(self, generation, line):
        if self.closing or generation != self.generation:
            return False
        if line.startswith("[STATE] "):
            try:
                values = tuple(map(int, line.split()[1:]))
                if len(values) == 7:
                    self.apply_state(values)
            except ValueError:
                pass
            return False
        if line.startswith("[PAIR-QR] "):
            self.qr_rows = line.split(" ", 1)[1].split("/")
            self.qr_button.set_sensitive(True)
            return False
        match = re.search(r"\[LISTENING\].*Pairing code (\d{6})", line)
        if match:
            self.pin = match.group(1)
            self.code_label.set_text(self.pin)
            self.status.set_text("Waiting for phone")
        elif "[CONNECTED]" in line or "[RESUMED]" in line:
            self.status.set_text("Phone connected")
        elif "[DISCONNECTED]" in line:
            self.status.set_text("Waiting for phone")
            self.apply_state(NEUTRAL)
        elif "[STALLED]" in line:
            self.status.set_text("Waiting for input")
            self.apply_state(NEUTRAL)
        self.log(line)
        return False

    def on_exit(self, generation, code):
        if not self.closing and generation == self.generation:
            self.process = None
            self.stop_receiver()
            self.status.set_text("Receiver stopped" if code == 0 else "Could not run receiver")
            self.log(f"Receiver exited ({code}). Check the activity above for details.")
        return False

    def apply_state(self, state):
        self.state = state
        buttons, lt, rt, lx, ly, rx, ry = state
        self.left.x, self.left.y = lx, ly
        self.right.x, self.right.y = rx, ry
        self.left.queue_draw()
        self.right.queue_draw()
        for bar, name, value in zip(self.triggers, ("LT", "RT"), (lt, rt)):
            bar.set_fraction(value / 255)
            bar.set_text(f"{name}  {round(value / 255 * 100)}%")
        for mask, widget in self.buttons.items():
            context = widget.get_style_context()
            (context.add_class if buttons & mask else context.remove_class)("pressed")
        if self.preview_ready:
            self.js("input", lx, ly, rx, ry, buttons, rt)

    def js(self, method, *args):
        script = "window.preview." + method + "(" + ",".join(json.dumps(a) for a in args) + ")"
        self.web.evaluate_javascript(script, -1, None, None, None, None, None)

    def catalog(self):
        self.models = {}
        data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
        # Retain custom models added before the PadRelay rename; new files take precedence.
        for directory in (HERE.parent / "server/assets", data_home / "kishi-receiver/Characters",
                          data_home / "padrelay-receiver/Characters"):
            self.models.update({p.name: p for p in directory.glob("*.glb") if p.is_file()})
        self.js("catalog", list(self.models))

    def preview_message(self, manager, result):
        try:
            message = json.loads(result.get_js_value().to_json(0))
            action = message.get("action")
            if action == "ready":
                self.preview_ready = True
                self.catalog()
                self.apply_state(self.state)
                self.js("visible", self.preview_toggle.get_active())
            elif action == "list":
                self.catalog()
            elif action == "load" and message.get("name") in self.models:
                name = message["name"]
                data = base64.b64encode(self.models[name].read_bytes()).decode("ascii")
                self.js("loaded", name, data)
        except (ValueError, OSError, TypeError) as error:
            self.log(f"Character preview: {error}")

    def navigation_policy(self, web, decision, kind):
        if kind == WebKit2.PolicyDecisionType.NAVIGATION_ACTION:
            if decision.get_navigation_action().get_request().get_uri() != (HERE / "build/preview/index.html").as_uri():
                decision.ignore()
                return True
        return False

    def toggle_preview(self, *_):
        visible = self.preview_toggle.get_active()
        self.web.set_visible(visible)
        if self.preview_ready:
            self.js("visible", visible)

    def show_qr(self, *_):
        dialog = Gtk.Dialog(title="Pair your phone", transient_for=self, modal=True)
        dialog.add_button("Close", Gtk.ResponseType.CLOSE)
        box = dialog.get_content_area()
        box.set_border_width(20)
        rows = list(self.qr_rows)
        area = Gtk.DrawingArea()
        area.set_size_request(296, 296)

        def draw(widget, cr):
            cr.set_source_rgb(1, 1, 1)
            cr.paint()
            size = len(rows)
            scale = min(widget.get_allocated_width(), widget.get_allocated_height()) // (size + 8)
            offset = (widget.get_allocated_width() - size * scale) / 2
            cr.set_source_rgb(0, 0, 0)
            for y, row in enumerate(rows):
                for x, cell in enumerate(row):
                    if cell == "1":
                        cr.rectangle(offset + x * scale, offset + y * scale, scale, scale)
            cr.fill()

        area.connect("draw", draw)
        box.pack_start(area, True, True, 0)
        box.pack_start(label(f"{self.address.get_active_id()} · {self.pin}"), False, False, 10)
        dialog.show_all()
        dialog.run()
        dialog.destroy()

    def enable_gamepad(self, *_):
        # Only the device setup command is elevated; the receiver stays unprivileged.
        self.log("Requesting permission to enable /dev/uinput for your account…")

        def enable():
            try:
                result = subprocess.run(["pkexec", "/bin/sh", str(HERE / "enable-gamepad.sh"),
                                         str(os.getuid())], capture_output=True, text=True)
                message = "Gamepad access enabled. Select Gamepad to play." if result.returncode == 0 else (
                    "Gamepad access was not enabled: " + (result.stderr.strip() or "authorization cancelled"))
            except OSError as error:
                message = f"Cannot request access: {error}"
            GLib.idle_add(self.access_result, message)

        threading.Thread(target=enable, daemon=True).start()

    def access_result(self, message):
        if not self.closing:
            self.log(message)
        return False

    def close(self, *_):
        self.closing = True
        self.stop_receiver()
        self.destroy()
        Gtk.main_quit()
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receiver", type=Path, default=HERE.parent / "server/target/release/padrelay-receiver")
    parser.add_argument("--monitor", action="store_true", help="Start without a virtual gamepad")
    args = parser.parse_args()
    ReceiverWindow(args.receiver, monitor=args.monitor)
    Gtk.main()


if __name__ == "__main__":
    main()
