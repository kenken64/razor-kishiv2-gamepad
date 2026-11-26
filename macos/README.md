# Kishi Receiver for macOS

Native SwiftUI receiver for the Kishi Wi-Fi protocol. It listens on TCP `26760`, pairs with the phone using a six-digit code, and either publishes a virtual gamepad through IOKit or shows live input in Monitor mode.

## Build and run

Requirements: macOS 13 or newer with Node.js 18 or newer, npm, and Xcode Command Line Tools (`xcode-select --install`).

```sh
./macos/build.sh
open "macos/build/Kishi Receiver.app"
```

Build a universal app on Apple Silicon:

```sh
ARCHS=universal ./macos/build.sh
```

The output is `macos/build/Kishi Receiver.app`. The build is ad-hoc signed by default and runs in **Monitor** mode.

Run the protocol and HID-report tests:

```sh
./macos/test.sh
```

## Character preview

The character preview opens on Sun Wukong. Choose a character by its English or Chinese name. The preview runs locally and responds to incoming reports in both receiver modes. Use the eye icon in the header to hide the model and show the live input monitor. Click it again to restore the model. The app remembers your choice.

| Action | Controller | Preview |
| --- | --- | --- |
| Walk or run | Left stick, hold RB to run | Drag Move or use WASD. Toggle Run or hold Shift. |
| Orbit and tilt | Right stick | Drag Look. Reset camera restores the starting angle. |
| Somersault jump | A | Jump or J |
| Swing or chain a follow-up | X | Fight or K |
| Weapon slam and shockwave | Y | Slam or I |
| Directional dodge or backstep | B | Dodge or L |
| 360° weapon swing | RT | Spin or U |
| Fullscreen | | Fullscreen or F11. Escape returns to the dashboard. |

Click inside the preview for keyboard controls. The model picker includes GLBs packaged from `server/assets` and compatible humanoid GLBs in `~/Library/Application Support/Kishi Receiver/Characters/`. Reopen the picker after copying a file. Models with matching filenames in the user folder override the bundled copy. The build downloads the rendering dependencies with npm and packages them with the app. Pairing and animation work offline on a local network.

## Modes

- **Gamepad** creates **Kishi Wi-Fi Gamepad** with IOKit and sends HID reports to macOS. If creation fails, the app logs the reason and falls back to Monitor.
- **Monitor** pairs with the phone and displays input but does not publish a gamepad. Use it to verify networking and controls without signing.

Use the mode picker at any time. Changing modes while running restarts the receiver. Pairing codes are regenerated on every start and restart.

## Signing for gamepad output

Apple restricts `com.apple.developer.hid.virtual.device` to apps signed with a provisioning profile that explicitly enables it. Create a macOS App ID and provisioning profile with that entitlement, then build with:

```sh
SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
PROVISIONING_PROFILE="/path/to/profile.provisionprofile" \
./macos/build.sh
```

The script parses the profile, applies the profile’s bundle identifier and entitlements, embeds the profile, and signs the app with hardened runtime. To re-sign an existing build:

```sh
sh ./macos/sign-macos.sh \
  "macos/build/Kishi Receiver.app" \
  "/path/to/profile.provisionprofile" \
  "Apple Development: Your Name (TEAMID)"
```

Confirm the device exists:

```sh
hidutil list | grep -i "Kishi Wi-Fi Gamepad"
```

## Troubleshooting

- **Port 26760 is busy.** Stop the Rust CLI receiver (`kishi-receiver`) or any other receiver, then restart the app.
- **No local-network access.** Allow the app in **System Settings → Privacy & Security → Local Network**, then restart it.
- **Gamepad unavailable.** The app is not signed with the virtual HID entitlement. Use the Signed build command above; Monitor mode remains available.
- **Phone cannot pair.** Check the Mac LAN address shown in the app, the current six-digit code, and that TCP `26760` is allowed by the firewall. Guest Wi-Fi may isolate devices.
- **Input stops.** The receiver releases controls after 750 ms without a complete report and disconnects after 4 seconds. The phone reconnects using its normal retry schedule.

## Source layout

- `KishiReceiverApp.swift` — app entry point and activation
- `ContentView.swift` — window layout, pairing card, receiver mode, activity log
- `InputPanel.swift` — live sticks, triggers, D-pad, and button indicators
- `ReceiverModel.swift` — UI state, start/stop, mode fallback, log formatting
- `ReceiverServer.swift` — TCP listener, pairing handshake, report parsing, ACK and timeouts
- `GamepadState.swift` — wire parsing, HID descriptor, HID report generation
- `VirtualGamepad.swift` — IOKit virtual HID device
- `LocalNetwork.swift` — LAN IPv4 address selection
- `build.sh`, `sign-macos.sh`, `Info.plist` — packaging and signing
