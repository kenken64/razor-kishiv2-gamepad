import Foundation
import AppKit

enum ReceiverMode: String, CaseIterable, Identifiable {
    case gamepad = "Gamepad"
    case monitor = "Monitor"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .gamepad:
            return "Publishes PadRelay Gamepad to macOS games."
        case .monitor:
            return "Pairs and shows input without creating a gamepad."
        }
    }
}

enum ReceiverLogLevel {
    case info
    case success
    case warning
    case error
}

struct ReceiverLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let level: ReceiverLogLevel
    let message: String
}

@MainActor
final class ReceiverModel: ObservableObject {
    @Published private(set) var selectedMode: ReceiverMode = .gamepad
    @Published private(set) var isRunning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isStalled = false
    @Published private(set) var hasGamepad = false
    @Published private(set) var gamepadError: String?
    @Published private(set) var pin = "------"
    @Published private(set) var localAddress = "Unavailable"
    @Published private(set) var peer = ""
    @Published private(set) var input = GamepadState()
    @Published private(set) var logs: [ReceiverLogEntry] = []
    @Published private(set) var lastError: String?

    private var server: ReceiverServer?
    private var gamepad: VirtualGamepad?
    private var didAutoStart = false

    var statusText: String {
        if lastError != nil, !isRunning { return "Error" }
        if !isRunning { return "Stopped" }
        if isConnected { return isStalled ? "Controls released" : "Connected" }
        return "Waiting for phone"
    }

    var statusDetail: String {
        if let lastError, !isRunning { return lastError }
        if !isRunning { return "Receiver is not listening" }
        if isConnected {
            return isStalled ? "No input for a moment; controls released" : "Streaming input from \(peer)"
        }
        return "Listening on TCP \(ReceiverServer.port)"
    }

    var statusColorName: String {
        if lastError != nil, !isRunning { return "red" }
        if !isRunning { return "secondary" }
        if isConnected { return isStalled ? "orange" : "green" }
        return "blue"
    }

    func startIfNeeded() {
        guard !didAutoStart else { return }
        didAutoStart = true
        start()
    }

    func start() {
        guard !isRunning else { return }
        lastError = nil
        gamepadError = nil
        hasGamepad = false
        isConnected = false
        isStalled = false
        peer = ""
        input = .init()
        pin = String(format: "%06d", Int.random(in: 0..<1_000_000))
        localAddress = LocalNetwork.primaryIPv4Address() ?? "Unavailable"

        if selectedMode == .gamepad {
            do {
                gamepad = try VirtualGamepad()
                hasGamepad = true
                log("Virtual gamepad created.", .success)
            } catch {
                gamepadError = error.localizedDescription
                hasGamepad = false
                selectedMode = .monitor
                log(error.localizedDescription, .warning)
                log("Falling back to Monitor mode.", .warning)
            }
        } else {
            log("Starting in Monitor mode; no gamepad will be published.", .info)
        }

        let server = ReceiverServer(pin: pin)
        server.delegate = self
        self.server = server
        isRunning = true
        log("Starting receiver on TCP \(ReceiverServer.port)...", .info)
        server.start()
    }

    func stop() {
        guard isRunning else { return }
        server?.delegate = nil
        server?.stop()
        server = nil
        isRunning = false
        isConnected = false
        isStalled = false
        peer = ""
        input = .init()
        resetGamepad()
        log("Receiver stopped.", .info)
    }

    func restart() {
        guard isRunning else {
            start()
            return
        }
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.start()
        }
    }

    func selectMode(_ mode: ReceiverMode) {
        guard selectedMode != mode else { return }
        selectedMode = mode
        if isRunning { restart() }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func copyAddress() {
        guard localAddress != "Unavailable" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(localAddress, forType: .string)
        log("Copied \(localAddress) to the clipboard.", .info)
    }

    private func resetGamepad() {
        if let gamepad {
            try? gamepad.update(.init())
        }
        gamepad = nil
        hasGamepad = false
    }

    private func apply(_ state: GamepadState) {
        input = state
        guard let gamepad else { return }
        do {
            try gamepad.update(state)
        } catch {
            gamepadError = error.localizedDescription
            self.gamepad = nil
            hasGamepad = false
            log(error.localizedDescription, .error)
            log("Continuing in Monitor mode.", .warning)
        }
    }

    private func log(_ message: String, _ level: ReceiverLogLevel = .info) {
        logs.append(ReceiverLogEntry(date: Date(), level: level, message: message))
        if logs.count > 400 {
            logs.removeFirst(logs.count - 400)
        }
    }
}

extension ReceiverModel: ReceiverServerDelegate {
    nonisolated func receiverServerDidStart(_ server: ReceiverServer) {
        Task { @MainActor in
            self.isRunning = true
            self.log("Pairing code \(self.pin).", .success)
        }
    }

    nonisolated func receiverServer(_ server: ReceiverServer, didFail message: String) {
        Task { @MainActor in
            self.lastError = message
            self.isRunning = false
            self.isConnected = false
            self.isStalled = false
            self.peer = ""
            self.resetGamepad()
            self.log(message, .error)
            if self.server === server {
                self.server = nil
            }
        }
    }

    nonisolated func receiverServer(_ server: ReceiverServer, didConnect peer: String) {
        Task { @MainActor in
            self.isConnected = true
            self.isStalled = false
            self.peer = peer
            self.input = .init()
            self.log("Phone connected from \(peer).", .success)
        }
    }

    nonisolated func receiverServer(
        _ server: ReceiverServer,
        didDisconnect peer: String,
        reason: String,
        wasPaired: Bool
    ) {
        Task { @MainActor in
            self.isConnected = false
            self.isStalled = false
            self.input = .init()
            self.resetGamepad()
            self.log(
                wasPaired ? "Phone disconnected: \(reason)" : "Pairing failed: \(reason)",
                wasPaired ? .warning : .error
            )
        }
    }

    nonisolated func receiverServer(_ server: ReceiverServer, didReceive state: GamepadState) {
        Task { @MainActor in
            if self.isStalled { self.isStalled = false }
            self.apply(state)
        }
    }

    nonisolated func receiverServerDidStall(_ server: ReceiverServer) {
        Task { @MainActor in
            self.isStalled = true
            self.input = .init()
            if let gamepad = self.gamepad {
                try? gamepad.update(.init())
            }
        }
    }

    nonisolated func receiverServerDidResume(_ server: ReceiverServer) {
        Task { @MainActor in
            self.isStalled = false
        }
    }

    nonisolated func receiverServer(_ server: ReceiverServer, log message: String) {
        Task { @MainActor in
            let level: ReceiverLogLevel
            if message.localizedCaseInsensitiveContains("failed")
                || message.localizedCaseInsensitiveContains("cannot") {
                level = .error
            } else if message.localizedCaseInsensitiveContains("rejected")
                || message.localizedCaseInsensitiveContains("disconnected") {
                level = .warning
            } else {
                level = .info
            }
            self.log(message, level)
        }
    }
}
