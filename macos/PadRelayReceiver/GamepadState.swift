import Foundation

/// One controller state as sent by the phone, plus the HID report used by macOS.
struct GamepadState: Equatable {
    static let ackRequest: UInt16 = 0x0800

    /// Wire button flags, in the order used by the phone protocol.
    static let buttons: [(name: String, mask: UInt16)] = [
        ("A", 0x1000),
        ("B", 0x2000),
        ("X", 0x4000),
        ("Y", 0x8000),
        ("LB", 0x0100),
        ("RB", 0x0200),
        ("Back", 0x0020),
        ("Start", 0x0010),
        ("Guide", 0x0400),
        ("LS", 0x0040),
        ("RS", 0x0080),
    ]

    var flags: UInt16 = 0
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
    var thumbLX: Int16 = 0
    var thumbLY: Int16 = 0
    var thumbRX: Int16 = 0
    var thumbRY: Int16 = 0

    var pressedButtons: UInt16 { flags & ~Self.ackRequest }

    var activeButtonNames: [String] {
        Self.buttons.filter { pressedButtons & $0.mask != 0 }.map(\.name)
    }

    /// Parse a 12-byte big-endian report from the phone.
    static func parse(_ bytes: [UInt8]) -> GamepadState? {
        guard bytes.count == 12 else { return nil }
        func axis(_ offset: Int) -> Int16 {
            Int16(bitPattern: UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
        }
        return GamepadState(
            flags: UInt16(bytes[0]) << 8 | UInt16(bytes[1]),
            leftTrigger: bytes[2],
            rightTrigger: bytes[3],
            thumbLX: axis(4),
            thumbLY: axis(6),
            thumbRX: axis(8),
            thumbRY: axis(10)
        )
    }

    var hat: (x: Int, y: Int) {
        let pressed = { (mask: UInt16) -> Int in pressedButtons & mask != 0 ? 1 : 0 }
        return (pressed(8) - pressed(4), pressed(2) - pressed(1))
    }

    /// Generic Desktop gamepad: 11 buttons, a four-bit hat, four signed
    /// 16-bit sticks and two unsigned 8-bit triggers. No report ID.
    static let hidDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x05, 0x09, 0x19, 0x01, 0x29, 0x0B,
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0B, 0x81, 0x02, 0x75, 0x05,
        0x95, 0x01, 0x81, 0x03, 0x05, 0x01, 0x09, 0x39, 0x25, 0x07, 0x46, 0x3B,
        0x01, 0x65, 0x14, 0x75, 0x04, 0x81, 0x42, 0x81, 0x03, 0x65, 0x00, 0x09,
        0x30, 0x09, 0x31, 0x09, 0x33, 0x09, 0x34, 0x16, 0x00, 0x80, 0x26, 0xFF,
        0x7F, 0x36, 0x00, 0x80, 0x46, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x04, 0x81,
        0x02, 0x09, 0x32, 0x09, 0x35, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x35, 0x00,
        0x46, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02, 0xC0,
    ]

    func hidReport() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 13)
        // A, B, X, Y, LB, RB, Back, Start, Guide, LS, RS.
        let masks: [UInt16] = [
            0x1000, 0x2000, 0x4000, 0x8000, 0x0100, 0x0200,
            0x0020, 0x0010, 0x0400, 0x0040, 0x0080,
        ]
        for (index, mask) in masks.enumerated() where pressedButtons & mask != 0 {
            bytes[index / 8] |= 1 << (index % 8)
        }
        let (x, y) = hat
        let table = [[7, 0, 1], [6, 8, 2], [5, 4, 3]]
        bytes[2] = UInt8(table[y + 1][x + 1])

        func saturatingNegate(_ value: Int16) -> Int16 {
            value == .min ? .max : -value
        }
        let axes = [thumbLX, saturatingNegate(thumbLY), thumbRX, saturatingNegate(thumbRY)]
        for (index, axis) in axes.enumerated() {
            let value = UInt16(bitPattern: axis)
            bytes[3 + index * 2] = UInt8(value & 0xFF)
            bytes[4 + index * 2] = UInt8(value >> 8)
        }
        bytes[11] = leftTrigger
        bytes[12] = rightTrigger
        return bytes
    }
}
