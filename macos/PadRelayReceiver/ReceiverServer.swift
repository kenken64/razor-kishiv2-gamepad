import Foundation
import Network

protocol ReceiverServerDelegate: AnyObject {
    func receiverServerDidStart(_ server: ReceiverServer)
    func receiverServer(_ server: ReceiverServer, didFail message: String)
    func receiverServer(_ server: ReceiverServer, didConnect peer: String)
    func receiverServer(_ server: ReceiverServer, didDisconnect peer: String, reason: String, wasPaired: Bool)
    func receiverServer(_ server: ReceiverServer, didReceive state: GamepadState)
    func receiverServerDidStall(_ server: ReceiverServer)
    func receiverServerDidResume(_ server: ReceiverServer)
    func receiverServer(_ server: ReceiverServer, log message: String)
}

/// TCP receiver for the PadRelay protocol.
///
/// The phone sends a 10-byte `KSH1` + six-digit pairing code handshake, expects
/// `OKR` back, then streams 12-byte big-endian input reports. Reports with the
/// acknowledgement flag set receive a one-byte `A` response.
final class ReceiverServer {
    static let port: UInt16 = 26760
    private static let stallAfter: TimeInterval = 0.75
    private static let disconnectAfter: TimeInterval = 4

    weak var delegate: ReceiverServerDelegate?
    let pin: String

    private let queue = DispatchQueue(label: "com.kishiwifi.receiver.network")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var handshakeBuffer = Data()
    private var reportBuffer = Data()
    private var handshakeComplete = false
    private var stalled = false
    private var lastReportAt = Date()
    private var watchdog: DispatchSourceTimer?
    private var stopped = false
    private var peerDescription = ""

    init(pin: String) {
        self.pin = pin
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.disconnectLocked(reason: "Receiver stopped")
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func startLocked() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(
                using: parameters,
                on: NWEndpoint.Port(rawValue: Self.port)!
            )
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptLocked(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.log("Listening on TCP \(Self.port)")
                    DispatchQueue.main.async {
                        guard let delegate = self.delegate else { return }
                        delegate.receiverServerDidStart(self)
                    }
                case .waiting(let error):
                    self.log("Listener waiting: \(error.localizedDescription)")
                case .failed(let error):
                    guard !self.stopped else { return }
                    self.listener?.cancel()
                    self.listener = nil
                    self.fail("Cannot listen on TCP \(Self.port): \(error.localizedDescription)")
                case .cancelled:
                    if !self.stopped {
                        self.fail("The TCP listener stopped.")
                    }
                case .setup:
                    break
                @unknown default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            fail("Cannot listen on TCP \(Self.port): \(error.localizedDescription)")
        }
    }

    private func acceptLocked(_ newConnection: NWConnection) {
        guard connection == nil else {
            log("Rejected an extra connection from \(String(describing: newConnection.endpoint)).")
            newConnection.cancel()
            return
        }
        connection = newConnection
        peerDescription = String(describing: newConnection.endpoint)
        handshakeBuffer.removeAll()
        reportBuffer.removeAll()
        handshakeComplete = false
        stalled = false

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection, self.connection === newConnection else { return }
            switch state {
            case .failed(let error):
                self.disconnectLocked(reason: error.localizedDescription)
            case .cancelled:
                self.disconnectLocked(reason: "Connection closed")
            default:
                break
            }
        }
        newConnection.start(queue: queue)
        log("Incoming connection from \(peerDescription)")

        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak newConnection] in
            guard let self, let newConnection, self.connection === newConnection else { return }
            if !self.handshakeComplete {
                self.disconnectLocked(reason: "Pairing timed out")
            }
        }
        readHandshake()
    }

    private func readHandshake() {
        guard let connection, !handshakeComplete else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 10 - handshakeBuffer.count
        ) { [weak self] data, _, isComplete, error in
            guard let self, self.connection != nil else { return }
            if let error {
                self.disconnectLocked(reason: error.localizedDescription)
                return
            }
            if let data, !data.isEmpty {
                self.handshakeBuffer.append(data)
            }
            if self.handshakeBuffer.count == 10 {
                let expected = Data("KSH1\(self.pin)".utf8)
                guard self.handshakeBuffer == expected else {
                    self.disconnectLocked(reason: "Incorrect pairing code or protocol")
                    return
                }
                self.completeHandshake()
                return
            }
            if isComplete {
                self.disconnectLocked(reason: "Peer closed during the pairing handshake")
                return
            }
            self.readHandshake()
        }
    }

    private func completeHandshake() {
        guard let connection else { return }
        handshakeComplete = true
        lastReportAt = Date()
        connection.send(content: Data("OKR".utf8), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.disconnectLocked(reason: error.localizedDescription)
        })
        startWatchdog()
        DispatchQueue.main.async {
            guard let delegate = self.delegate else { return }
            delegate.receiverServer(self, didConnect: self.peerDescription)
        }
        receiveReports()
    }

    private func receiveReports() {
        guard let connection, handshakeComplete else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 4096
        ) { [weak self] data, _, isComplete, error in
            guard let self, self.connection != nil else { return }
            if let error {
                self.disconnectLocked(reason: error.localizedDescription)
                return
            }
            if let data, !data.isEmpty {
                self.consumeReports(data)
            }
            if isComplete {
                self.disconnectLocked(reason: "Peer closed the connection")
                return
            }
            self.receiveReports()
        }
    }

    private func consumeReports(_ data: Data) {
        reportBuffer.append(data)
        while reportBuffer.count >= 12 {
            let bytes = Array(reportBuffer.prefix(12))
            reportBuffer.removeFirst(12)
            guard let state = GamepadState.parse(bytes) else { continue }
            lastReportAt = Date()
            if stalled {
                stalled = false
                log("Input restored")
                DispatchQueue.main.async {
                    self.delegate?.receiverServerDidResume(self)
                }
            }
            DispatchQueue.main.async {
                self.delegate?.receiverServer(self, didReceive: state)
            }
            if state.flags & GamepadState.ackRequest != 0 {
                sendAck()
            }
        }
    }

    private func sendAck() {
        connection?.send(content: Data("A".utf8), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.log("Acknowledgement failed: \(error.localizedDescription)")
        })
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        watchdog = timer
        timer.resume()
    }

    private func watchdogTick() {
        guard connection != nil, handshakeComplete else { return }
        let silence = Date().timeIntervalSince(lastReportAt)
        if !stalled, silence >= Self.stallAfter {
            stalled = true
            log("Controls released; waiting for input")
            DispatchQueue.main.async {
                guard let delegate = self.delegate else { return }
                delegate.receiverServerDidStall(self)
            }
        }
        if silence >= Self.disconnectAfter {
            disconnectLocked(reason: "No complete input report for 4 seconds")
        }
    }

    private func disconnectLocked(reason: String) {
        guard let connection else { return }
        let wasPaired = handshakeComplete
        self.connection = nil
        handshakeComplete = false
        stalled = false
        handshakeBuffer.removeAll()
        reportBuffer.removeAll()
        watchdog?.cancel()
        watchdog = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let peer = peerDescription
        peerDescription = ""
        DispatchQueue.main.async {
            guard let delegate = self.delegate else { return }
            delegate.receiverServer(self, didDisconnect: peer, reason: reason, wasPaired: wasPaired)
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            guard let delegate = self.delegate else { return }
            delegate.receiverServer(self, didFail: message)
        }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.delegate?.receiverServer(self, log: message)
        }
    }
}
