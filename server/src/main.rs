use std::{
    error::Error,
    hash::{BuildHasher, RandomState},
    io::{self, IsTerminal, Read, Write},
    net::{TcpListener, TcpStream},
    time::Duration,
};
use vigem_client::{Client, TargetId, XGamepad, Xbox360Wired};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn timestamp() -> String {
    chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, false)
}

fn receive(
    mut socket: TcpStream,
    pin: &str,
    paired: &mut bool,
    mut apply: impl FnMut(XGamepad) -> Result<()>,
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
    socket.set_read_timeout(Some(Duration::from_millis(750)))?;
    *paired = true;
    println!("{} [CONNECTED] {}", timestamp(), socket.peer_addr()?);
    loop {
        let mut b = [0; 12];
        socket.read_exact(&mut b)?;
        let axis = |i: usize| i16::from_be_bytes([b[i], b[i + 1]]);
        let flags = u16::from_be_bytes([b[0], b[1]]);
        const ACK_REQUEST: u16 = 0x0800;
        apply(XGamepad {
            buttons: (flags & !ACK_REQUEST).into(),
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
    let monitor = std::env::args().any(|a| a == "--monitor");
    let mut target = if monitor {
        None
    } else {
        let client = Client::connect().map_err(|e| format!("Cannot open ViGEmBus ({e}). Install the ViGEmBus Windows driver and restart the receiver."))?;
        let mut pad = Xbox360Wired::new(client, TargetId::XBOX360_WIRED);
        pad.plugin()?;
        pad.wait_ready()?;
        Some(pad)
    };
    let listener = TcpListener::bind(("0.0.0.0", 26760))?;
    let pin = format!("{:06}", RandomState::new().hash_one("pair") % 1000000);
    println!("{} [LISTENING] TCP 26760. Pairing code {pin}", timestamp());
    for socket in listener.incoming() {
        let mut previous = None;
        let socket = socket?;
        let peer = socket.peer_addr()?;
        let mut paired = false;
        let result = receive(socket, &pin, &mut paired, |state| {
            if let Some(pad) = &mut target {
                pad.update(&state)?;
            } else if previous != Some(state) {
                println!("{} [INPUT] {peer} {state:?}", timestamp());
                previous = Some(state);
            }
            Ok(())
        });
        if let Some(pad) = &mut target {
            pad.update(&XGamepad::default())?;
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
