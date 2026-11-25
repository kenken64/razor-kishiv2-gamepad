import Foundation
import IOKit.hidsystem
import Darwin.Mach

enum VirtualGamepadError: LocalizedError {
    case missingEntitlement
    case reportFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .missingEntitlement:
            return "Cannot create the virtual gamepad. Sign the app with com.apple.developer.hid.virtual.device, or run in Monitor mode."
        case .reportFailed(let status):
            return String(format: "Virtual HID input failed (0x%08X).", UInt32(bitPattern: status))
        }
    }
}

/// Publishes the receiver as a virtual gamepad through IOKit.
final class VirtualGamepad {
    private let device: IOHIDUserDevice
    private let queue = DispatchQueue(label: "com.kishiwifi.receiver.hid")

    init() throws {
        let properties: [String: Any] = [
            "ReportDescriptor": Data(GamepadState.hidDescriptor),
            "Product": "Kishi Wi-Fi Gamepad",
            "Transport": "Virtual",
        ]
        guard let device = IOHIDUserDeviceCreateWithProperties(
            kCFAllocatorDefault,
            properties as CFDictionary,
            0
        ) else {
            throw VirtualGamepadError.missingEntitlement
        }
        self.device = device
        IOHIDUserDeviceSetDispatchQueue(device, queue)
        IOHIDUserDeviceActivate(device)
        try update(.init())
    }

    func update(_ state: GamepadState) throws {
        let report = state.hidReport()
        let status = report.withUnsafeBufferPointer { buffer in
            IOHIDUserDeviceHandleReportWithTimeStamp(
                device,
                mach_absolute_time(),
                buffer.baseAddress!,
                CFIndex(buffer.count)
            )
        }
        guard status == kIOReturnSuccess else {
            throw VirtualGamepadError.reportFailed(status)
        }
    }

    deinit {
        IOHIDUserDeviceCancel(device)
    }
}
