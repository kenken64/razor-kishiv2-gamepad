import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

func testParsing() {
    let wire: [UInt8] = [
        0x18, 0x00, 120, 10,
        0xFF, 0xFE, 0x80, 0x00, 0x01, 0x00, 0xFF, 0xFF,
    ]
    let state = GamepadState.parse(wire)!
    expect(state.flags == 0x1800, "flags are big-endian")
    expect(state.pressedButtons == 0x1000, "ack bit is stripped from buttons")
    expect(state.activeButtonNames == ["A"], "A is active")
    expect(state.leftTrigger == 120, "left trigger")
    expect(state.rightTrigger == 10, "right trigger")
    expect(state.thumbLX == -2, "left X is signed big-endian")
    expect(state.thumbLY == -32768, "left Y is signed big-endian")
    expect(state.thumbRX == 256, "right X")
    expect(state.thumbRY == -1, "right Y")
    expect(GamepadState.parse([0, 1, 2]) == nil, "short reports are rejected")
}

func testHIDReportMatchesRust() {
    var state = GamepadState()
    state.flags = 0x9FC9
    state.leftTrigger = 12
    state.rightTrigger = 250
    state.thumbLX = -2
    state.thumbLY = -32768
    state.thumbRX = 256
    state.thumbRY = 1
    let expected: [UInt8] = [57, 7, 1, 254, 255, 255, 127, 0, 1, 255, 255, 12, 250]
    expect(state.hidReport() == expected, "HID report matches the Rust receiver")
    expect(state.hidReport().count == 13, "HID report length")
}

func testHat() {
    var state = GamepadState()
    state.flags = 0x0002
    expect(state.hat == (0, 1), "up hat")
    expect(state.hidReport()[2] == 4, "up hat report")
    state.flags = 0x0004
    expect(state.hat == (-1, 0), "right hat")
    expect(state.hidReport()[2] == 6, "right hat report")
    state.flags = 0x0009
    expect(state.hat == (1, -1), "down-left hat")
    expect(state.hidReport()[2] == 1, "down-left hat report")
    state.flags = 0
    expect(state.hidReport()[2] == 8, "neutral hat")
}

func testNeutralReport() {
    let report = GamepadState().hidReport()
    expect(report == [0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "neutral HID report")
}

testParsing()
testHIDReportMatchesRust()
testHat()
testNeutralReport()
print("All protocol tests passed.")
