use crate::Gamepad;

// Generic Desktop gamepad: 11 buttons, a four-bit hat (8 = neutral),
// four signed 16-bit sticks and two unsigned 8-bit triggers. No report ID.
pub const DESCRIPTOR: &[u8] = &[
    0x05, 1, 0x09, 5, 0xa1, 1, 0x05, 9, 0x19, 1, 0x29, 11, 0x15, 0, 0x25, 1, 0x75, 1, 0x95, 11,
    0x81, 2, 0x75, 5, 0x95, 1, 0x81, 3, 0x05, 1, 0x09, 0x39, 0x25, 7, 0x46, 0x3b, 1, 0x65, 0x14,
    0x75, 4, 0x81, 0x42, 0x81, 3, 0x65, 0, 0x09, 0x30, 0x09, 0x31, 0x09, 0x33, 0x09, 0x34, 0x16, 0,
    0x80, 0x26, 0xff, 0x7f, 0x36, 0, 0x80, 0x46, 0xff, 0x7f, 0x75, 16, 0x95, 4, 0x81, 2, 0x09,
    0x32, 0x09, 0x35, 0x15, 0, 0x26, 0xff, 0, 0x35, 0, 0x46, 0xff, 0, 0x75, 8, 0x95, 2, 0x81, 2,
    0xc0,
];

pub fn report(pad: &Gamepad) -> [u8; 13] {
    let mut bytes = [0; 13];
    // A, B, X, Y, LB, RB, Back, Start, Guide, LS, RS.
    let masks = [
        0x1000, 0x2000, 0x4000, 0x8000, 0x100, 0x200, 0x20, 0x10, 0x400, 0x40, 0x80,
    ];
    for (i, mask) in masks.iter().enumerate() {
        if pad.buttons & mask != 0 {
            bytes[i / 8] |= 1 << (i % 8);
        }
    }
    let (x, y) = pad.hat();
    bytes[2] = [[7, 0, 1], [6, 8, 2], [5, 4, 3]][(y + 1) as usize][(x + 1) as usize];
    for (dest, axis) in bytes[3..11].chunks_exact_mut(2).zip(pad.sticks()) {
        dest.copy_from_slice(&axis.to_le_bytes());
    }
    bytes[11] = pad.left_trigger;
    bytes[12] = pad.right_trigger;
    bytes
}

#[test]
fn hid_matches_wire_axes_buttons_and_hat() {
    assert_eq!(DESCRIPTOR.last(), Some(&0xc0));
    assert_eq!(report(&Gamepad::default())[2], 8);
    let pad = Gamepad {
        buttons: 0x9fc9,
        left_trigger: 12,
        right_trigger: 250,
        thumb_lx: -2,
        thumb_ly: -32768,
        thumb_rx: 256,
        thumb_ry: 1,
    };
    assert_eq!(
        report(&pad),
        [57, 7, 1, 254, 255, 255, 127, 0, 1, 255, 255, 12, 250]
    );
}
