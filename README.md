# Kishi Wi-Fi

Use a Razer Kishi V2 attached to an Android phone as a wireless gamepad for Windows, Linux, macOS, or a second Android device. The phone reads the Kishi over USB-C and sends buttons, sticks, and triggers over Wi-Fi. The Rust desktop receiver creates an Xbox 360 controller on Windows and a virtual gamepad on Linux or macOS.

The phone and PC must be on the same local network. The PC can use Ethernet. Use a trusted LAN because the pairing code and controller reports travel over unencrypted TCP.

## Start the Windows receiver

Install Rust with Cargo and the Windows MSVC build tools. Install the [ViGEmBus driver](https://github.com/nefarius/ViGEmBus/releases/tag/v1.22.0) on the PC that will run the game.

From the repository root, run these commands in PowerShell:

```powershell
ipconfig
cargo run --locked --release --manifest-path .\server\Cargo.toml
```

Find the IPv4 address of the PC’s active Ethernet or Wi-Fi adapter in the first command’s output. The receiver prints a six-digit pairing code when it starts listening on TCP port `26760`. Keep the receiver running while playing. If Windows Firewall prompts you, allow the receiver on your private network.

## Start the Linux receiver

The receiver needs read/write access to `/dev/uinput`. If the device is missing, load the kernel module with `sudo modprobe uinput`. On a system with ACL tools, grant your account access to the current device node with `sudo setfacl -m "u:$(id -un):rw" /dev/uinput`. [Linux uinput documentation](https://docs.kernel.org/input/uinput.html)

Extract the Linux x86-64 archive and run `./kishi-receiver`. To build and run from source with Rust and Cargo, use the following command from the repository root.

```sh
cargo run --locked --release --manifest-path server/Cargo.toml
```

Find your active LAN IPv4 address with `ip -br -4 addr`. Enter it and the six-digit code printed in the terminal on the Kishi phone, then tap **Connect**. To verify game input, open `evtest`, select **Kishi Wi-Fi Gamepad**, and move a stick or press a button.

## Start the macOS receiver

The receiver publishes **Kishi Wi-Fi Gamepad** through IOKit. Gamepad mode requires a signing identity and a macOS provisioning profile for an explicit App ID authorized for Apple’s virtual HID entitlement. To test pairing and view live input before signing, extract the archive for your processor and run `./kishi-receiver --monitor`. [Apple virtual HID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device)

From the extracted directory, substitute your profile and signing identity, then launch the signed receiver in Terminal to see the pairing code.

```sh
sh sign-macos.sh ./kishi-receiver "/path/to/profile.provisionprofile" "Apple Development: Your Name (TEAMID)"
"./Kishi Receiver.app/Contents/MacOS/kishi-receiver"
```

To build from source with Rust and Xcode Command Line Tools, run these commands from the repository root.

```sh
cargo build --locked --release --manifest-path server/Cargo.toml --target-dir server/target
sh server/sign-macos.sh server/target/release/kishi-receiver "/path/to/profile.provisionprofile" "Apple Development: Your Name (TEAMID)"
"./Kishi Receiver.app/Contents/MacOS/kishi-receiver"
```

Enter the Mac’s LAN IPv4 address (shown in **System Settings → Network**) and the six-digit pairing code on the phone. Allow incoming connections if macOS prompts. Run `hidutil list` to check that **Kishi Wi-Fi Gamepad** appears, then test the buttons and sticks in a HID-controller-compatible game.

## Build and install the Android app

The app runs on Android 6.0 (API 23) or newer. To build it on Windows, install a JDK such as JDK 17 and put `java`, `javac`, `jar`, and `keytool` on your PATH. Install Android SDK Platform 35 and Build Tools 35.0.0.

```powershell
.\android\build.ps1
```

The script defaults to `D:\Android\Sdk`. For another SDK location, pass its path with `-Sdk`. It compiles the app, signs it with a local debug key, and verifies the APK.

Copy **`android\build\Kishi-WiFi.apk`** to the phone and tap it to install. If prompted, allow installation from the app opening the file. Keep `android\build\debug.jks` locally so future builds can update the installed app and preserve its profiles.

## Pair and test

### Receive on a Google Pixel 7 Pro

Install the APK on the Kishi phone as usual. On the receiving Pixel, enable Developer options and authorize USB debugging or pair wireless ADB. From PowerShell run the setup script with the Pixel connected:

```powershell
.\android\Enable-PixelReceiver.ps1                       # USB
.\android\Enable-PixelReceiver.ps1 -Serial 'IP:PORT'     # paired wireless ADB connection
```

Run one of those commands. It installs the APK and starts the shell helper that creates an Android gamepad. Repeat after a Pixel reboot. In **Receiver mode**, tap **Start receiver**. On the Kishi phone, enter the Pixel’s Wi-Fi address and the six-digit code displayed in the receiver screen. Once paired, open a controller-compatible game on the Pixel and keep the sender app open on the Kishi phone. The Pixel receives in the background and can be disconnected from ADB. To end the session, open **Receiver mode → Stop receiver**. Starting the receiver again generates a new gamepad pairing code.

### Receive on Windows

1. Attach the Kishi and open **Kishi Wi-Fi**. Move a stick and check that the landscape input monitor responds before pairing.
2. Enter the PC’s IPv4 address and the six-digit code from the receiver window, then tap **Connect**. Keep the app in the foreground.
3. On Windows, press **Win + R**, enter `joy.cpl`, select the Xbox 360 controller, and open **Properties → Test**. Press a button or move a stick to verify that Windows receives it.

**Saved receivers.** Tap **Profiles → Save current address** and give the PC a name. The app restores the last address on launch. To switch PCs, disconnect and select another profile. Each receiver launch generates a fresh pairing code.

**Automatic reconnect.** After pairing, the app retries a dropped connection after 1, 2, 4, then 8 seconds between attempts. Tap **Disconnect** to cancel. If the PC receiver restarts, enter its new pairing code.

**Receiver RTT.** About once per second, the phone times an input report that requests an acknowledgement. In gamepad mode the receiver acknowledges it after applying the report to the virtual controller. The displayed milliseconds cover that round trip. Game rendering and display latency are outside the measurement.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| The receiver reports `Cannot open ViGEmBus` | Install the driver on Windows and restart the receiver. |
| The phone cannot pair | Check the current code, the PC’s LAN address, and private-network firewall access for TCP port `26760`. Guest Wi-Fi may isolate devices. |
| The phone connects but the game sees no input | Use gamepad mode. Check `joy.cpl` on Windows, `evtest` on Linux, or `hidutil list` on macOS. |
| Input stops when switching apps | Return to Kishi Wi-Fi. The app releases the connection while paused and attempts to reconnect when the same activity resumes. |

To inspect incoming controller states in the terminal, stop the receiver with **Ctrl+C** and start monitor mode:

```powershell
cargo run --locked --release --manifest-path .\server\Cargo.toml -- --monitor
```

Pair using the newly printed code. This mode logs state changes and works without ViGEmBus. Restart in normal mode to play.
