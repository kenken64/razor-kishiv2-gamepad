use std::{
    error::Error,
    hash::{BuildHasher, RandomState},
    io::{self, IsTerminal, Read, Write},
    net::{TcpListener, TcpStream},
    time::{Duration, Instant},
};
#[cfg_attr(windows, path = "windows.rs")]
#[cfg_attr(target_os = "linux", path = "linux.rs")]
#[cfg_attr(target_os = "macos", path = "macos.rs")]
mod device;

#[cfg(any(target_os = "macos", test))]
mod hid;

#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
struct Gamepad {
    buttons: u16,
    left_trigger: u8,
    right_trigger: u8,
    thumb_lx: i16,
    thumb_ly: i16,
    thumb_rx: i16,
    thumb_ry: i16,
}

#[cfg(any(target_os = "linux", target_os = "macos", test))]
impl Gamepad {
    fn hat(self) -> (i8, i8) {
        let pressed = |mask| i8::from(self.buttons & mask != 0u16);
        (pressed(8) - pressed(4), pressed(2) - pressed(1))
    }

    fn sticks(self) -> [i16; 4] {
        [
            self.thumb_lx,
            self.thumb_ly.saturating_neg(),
            self.thumb_rx,
            self.thumb_ry.saturating_neg(),
        ]
    }
}

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn timestamp() -> String {
    chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, false)
}

fn receive(
    mut socket: TcpStream,
    pin: &str,
    paired: &mut bool,
    mut apply: impl FnMut(Gamepad) -> Result<()>,
) -> Result<()> {
    socket.set_read_timeout(Some(Duration::from_secs(2)))?;
    let mut hello = [0; 10];
    socket.read_exact(&mut hello)?;
    if hello[..4] != *b"KSH1" || hello[4..] != *pin.as_bytes() {
        return Err("Incorrect pairing code or protocol".into());
    }
    socket.set_nodelay(true)?;
    socket.set_write_timeout(Some(Duration::from_millis(750)))?;
    // R advertises optional report acknowledgements after the legacy OK handshake.
    socket.write_all(b"OKR")?;
    const RELEASE_AFTER: Duration = Duration::from_millis(750);
    const DISCONNECT_AFTER: Duration = Duration::from_secs(4);
    socket.set_read_timeout(Some(Duration::from_millis(250)))?;
    *paired = true;
    let peer = socket.peer_addr()?;
    println!("{} [CONNECTED] {peer}", timestamp());
    let mut b = [0; 12];
    let mut filled = 0;
    let mut last_report = Instant::now();
    let mut stalled = false;
    loop {
        match socket.read(&mut b[filled..]) {
            Ok(0) if filled == 0 => return Err("Peer closed the connection".into()),
            Ok(0) => {
                return Err(
                    format!("Peer closed during a report ({filled}/12 bytes received)").into(),
                )
            }
            Ok(n) => filled += n,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::TimedOut
                        | io::ErrorKind::WouldBlock
                        | io::ErrorKind::Interrupted
                ) => {}
            Err(e) => return Err(e.into()),
        }
        if filled < b.len() {
            let silence = last_report.elapsed();
            if !stalled && silence >= RELEASE_AFTER {
                apply(Gamepad::default())?;
                stalled = true;
                println!(
                    "{} [STALLED] {peer} Controls released; waiting for input",
                    timestamp()
                );
            }
            if silence >= DISCONNECT_AFTER {
                return Err("No complete input report for 4 seconds".into());
            }
            continue;
        }
        if stalled {
            println!("{} [RESUMED] {peer} Input restored", timestamp());
            stalled = false;
        }
        last_report = Instant::now();
        filled = 0;
        let axis = |i: usize| i16::from_be_bytes([b[i], b[i + 1]]);
        let flags = u16::from_be_bytes([b[0], b[1]]);
        const ACK_REQUEST: u16 = 0x0800;
        apply(Gamepad {
            buttons: flags & !ACK_REQUEST,
            left_trigger: b[2],
            right_trigger: b[3],
            thumb_lx: axis(4),
            thumb_ly: axis(6),
            thumb_rx: axis(8),
            thumb_ry: axis(10),
        })?;
        if flags & ACK_REQUEST != 0 {
            socket.write_all(b"A")?;
        }
    }
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let monitor = args.iter().any(|a| a == "--monitor");
    let ui = args.iter().any(|a| a == "--ui");
    let mut target = if monitor {
        None
    } else {
        Some(device::Device::open()?)
    };
    let listener = TcpListener::bind(("0.0.0.0", 26760))?;
    let pin = format!("{:06}", RandomState::new().hash_one("pair") % 1000000);
    println!("{} [LISTENING] TCP 26760. Pairing code {pin}", timestamp());
    for socket in listener.incoming() {
        let mut previous = None;
        let mut ui_buttons = 0;
        let mut ui_spin_held = false;
        let mut last_ui = Instant::now() - Duration::from_secs(1);
        let socket = socket?;
        let peer = socket.peer_addr()?;
        let mut paired = false;
        let result = receive(socket, &pin, &mut paired, |state| {
            let spin_held =
                state.right_trigger >= 140 || (ui_spin_held && state.right_trigger > 80);
            if ui
                && (state.buttons != ui_buttons
                    || spin_held != ui_spin_held
                    || last_ui.elapsed() >= Duration::from_millis(50))
            {
                println!(
                    "[STATE] {} {} {} {} {} {} {}",
                    state.buttons,
                    state.left_trigger,
                    state.right_trigger,
                    state.thumb_lx,
                    state.thumb_ly,
                    state.thumb_rx,
                    state.thumb_ry
                );
                last_ui = Instant::now();
                ui_buttons = state.buttons;
                ui_spin_held = spin_held;
            }
            if let Some(pad) = &mut target {
                pad.update(&state)?;
            } else if !ui && previous != Some(state) {
                println!("{} [INPUT] {peer} {state:?}", timestamp());
                previous = Some(state);
            }
            Ok(())
        });
        if let Some(pad) = &mut target {
            pad.update(&Gamepad::default())?;
        }
        if let Err(e) = result {
            let label = match (paired, io::stderr().is_terminal()) {
                (true, true) => "\x1b[1;31m[DISCONNECTED]\x1b[0m",
                (true, false) => "[DISCONNECTED]",
                (false, _) => "[PAIRING FAILED]",
            };
            eprintln!("{} {label} {peer} {e}", timestamp());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{sync::mpsc, thread};

    #[test]
    fn fragmented_report_survives_stall_and_controls_are_released() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let mut phone = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        phone
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let (updates, states) = mpsc::channel();
        let server = thread::spawn(move || {
            let (socket, _) = listener.accept().unwrap();
            receive(socket, "123456", &mut false, |pad| {
                updates.send(pad)?;
                Ok(())
            })
            .unwrap_err()
            .to_string()
        });
        phone.write_all(b"KSH1123456").unwrap();
        let mut ok = [0; 3];
        phone.read_exact(&mut ok).unwrap();
        assert_eq!(&ok, b"OKR");
        let mut report = [0; 12];
        report[0] = 0x18; // A button plus an acknowledgement request.
        report[2] = 120;
        phone.write_all(&report).unwrap();
        let next = || states.recv_timeout(Duration::from_secs(3)).unwrap();
        let first = next();
        assert_eq!(first.left_trigger, 120);
        assert_eq!(first.buttons, 0x1000);
        let mut ack = [0];
        phone.read_exact(&mut ack).unwrap();
        assert_eq!(&ack, b"A");
        report[2] = 220;
        phone.write_all(&report[..5]).unwrap();
        assert_eq!(next(), Gamepad::default());
        phone.write_all(&report[5..]).unwrap();
        assert_eq!(next().left_trigger, 220);
        phone.shutdown(std::net::Shutdown::Write).unwrap();
        assert_eq!(server.join().unwrap(), "Peer closed the connection");
    }

    #[test]
    fn silent_peer_eventually_releases_the_session() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let mut phone = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        phone.write_all(b"KSH1123456").unwrap();
        let (socket, _) = listener.accept().unwrap();
        let error = receive(socket, "123456", &mut false, |_| Ok(())).unwrap_err();
        assert_eq!(error.to_string(), "No complete input report for 4 seconds");
    }
}
