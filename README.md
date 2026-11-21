# Kishi Wi-Fi

Use a Razer Kishi V2 attached to an Android phone as an Xbox 360 controller for Windows games. The Android app reads the Kishi over USB-C and sends button, stick, and trigger updates over Wi-Fi. A Rust receiver on the PC applies those updates to a virtual Xbox 360 controller through ViGEmBus.

The phone and PC must be on the same local network. The PC can use Ethernet. Use a trusted LAN because the pairing code and controller reports travel over unencrypted TCP.

## Start the Windows receiver

Install Rust with Cargo and the Windows MSVC build tools. Install the [ViGEmBus driver](https://github.com/nefarius/ViGEmBus/releases/tag/v1.22.0) on the PC that will run the game.

From the repository root, run these commands in PowerShell:

```powershell
ipconfig
cargo run --locked --release --manifest-path .\server\Cargo.toml
```

Find the IPv4 address of the PC’s active Ethernet or Wi-Fi adapter in the first command’s output. The receiver prints a six-digit pairing code when it starts listening on TCP port `26760`. Keep the receiver running while playing. If Windows Firewall prompts you, allow the receiver on your private network.

## Build and install the Android app

The app runs on Android 6.0 (API 23) or newer. To build it on Windows, install a JDK such as JDK 17 and put `java`, `javac`, `jar`, and `keytool` on your PATH. Install Android SDK Platform 35 and Build Tools 35.0.0.

```powershell
.\android\build.ps1
```

The script defaults to `D:\Android\Sdk`. For another SDK location, pass its path with `-Sdk`. It compiles the app, signs it with a local debug key, and verifies the APK.

Copy **`android\build\Kishi-WiFi.apk`** to the phone and tap it to install. If prompted, allow installation from the app opening the file. Keep `android\build\debug.jks` locally so future builds can update the installed app and preserve its profiles.

## Pair and test

1. Attach the Kishi and open **Kishi Wi-Fi**. Move a stick and check that the landscape input monitor responds before pairing.
2. Enter the PC’s IPv4 address and the six-digit code from the receiver window, then tap **Connect**. Keep the app in the foreground.
3. On Windows, press **Win + R**, enter `joy.cpl`, select the Xbox 360 controller, and open **Properties → Test**. Press a button or move a stick to verify that Windows receives it.

**Saved receivers.** Tap **Profiles → Save current address** and give the PC a name. The app restores the last address on launch. To switch PCs, disconnect and select another profile. Each receiver launch generates a fresh pairing code.

**Receiver RTT.** About once per second, the phone times an input report that requests an acknowledgement. In gamepad mode the receiver acknowledges it after applying the report to the virtual controller. The displayed milliseconds cover that round trip. Game rendering and display latency are outside the measurement.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| The receiver reports `Cannot open ViGEmBus` | Install the driver on Windows and restart the receiver. |
| The phone cannot pair | Check the current code, the PC’s LAN address, and private-network firewall access for TCP port `26760`. Guest Wi-Fi may isolate devices. |
| The phone connects but the game sees no input | Check the controller in `joy.cpl`. Use normal receiver mode for games. |
| Input stops when switching apps | Return to Kishi Wi-Fi and reconnect. Leaving the activity ends the session and the receiver releases held controls. |

To inspect incoming controller states in the terminal, stop the receiver with **Ctrl+C** and start monitor mode:

```powershell
cargo run --locked --release --manifest-path .\server\Cargo.toml -- --monitor
```

Pair using the newly printed code. This mode logs state changes and works without ViGEmBus. Restart in normal mode to play.
