import SwiftUI
import CoreImage

struct ContentView: View {
    @ObservedObject var model: ReceiverModel

    @AppStorage("showCharacterPreview") private var showingCharacter = true

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 18) {
                HeaderView(showingCharacter: $showingCharacter, model: model)

                HStack(alignment: .top, spacing: 18) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 18) {
                            PairingPanel(model: model)
                            if showingCharacter {
                                CharacterPreview(model: model, visible: true)
                                    .frame(height: 360)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            }
                        }
                    }
                    .frame(width: 360)
                    .frame(maxHeight: .infinity, alignment: .top)

                    VStack(spacing: 18) {
                        InputPanel(model: model)

                        HStack(alignment: .top, spacing: 18) {
                            ReceiverPanel(model: model)
                                .frame(width: 300)
                            ActivityPanel(model: model)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(22)
        }
        .preferredColorScheme(.dark)
        .onAppear { model.startIfNeeded() }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @Binding var showingCharacter: Bool
    @ObservedObject var model: ReceiverModel

    private var statusColor: Color {
        if model.lastError != nil, !model.isRunning { return .red }
        if !model.isRunning { return .gray }
        if model.isConnected { return model.isStalled ? .orange : .green }
        return .cyan
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0x2DD4BF), Color(hex: 0x0EA5A0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.82))
            }
            .frame(width: 52, height: 52)
            .shadow(color: Color(hex: 0x2DD4BF).opacity(0.35), radius: 12, y: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text("Kishi Receiver")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                Text("Razer Kishi V2 · wireless bridge to macOS")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            StatusBadge(text: model.statusText, color: statusColor, pulsing: model.isRunning && !model.isConnected)

            Button { showingCharacter.toggle() } label: {
                Image(systemName: showingCharacter ? "eye" : "eye.slash")
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showingCharacter ? "Hide 3D model" : "Show 3D model")
            .help(showingCharacter ? "Hide 3D model" : "Show 3D model")

            if model.isRunning {
                Button(action: model.restart) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                        .overlay(Circle().stroke(Color.white.opacity(0.09), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Restart with a new pairing code")
            }

            Button(action: { model.isRunning ? model.stop() : model.start() }) {
                Label(
                    model.isRunning ? "Stop" : "Start receiver",
                    systemImage: model.isRunning ? "stop.fill" : "play.fill"
                )
                .font(.system(size: 14.5, weight: .semibold))
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(
                    Capsule().fill(
                        model.isRunning ? Color.white.opacity(0.09) : Color(hex: 0x2DD4BF)
                    )
                )
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                .foregroundStyle(model.isRunning ? Color.primary : Color.black.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 2)
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color
    let pulsing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 1))
    }
}

// MARK: - Pairing

private struct PairingQRView: View {
    let payload: String
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: CGFloat(image.width) * 8, height: CGFloat(image.height) * 8)
                    .padding(32)
                    .background(Color.white)
                    .accessibilityLabel("Pairing QR code")
            } else {
                Text("Preparing pairing QR code…").padding()
            }
        }
        .task(id: payload) {
            let filter = CIFilter(name: "CIQRCodeGenerator", parameters: [
                "inputMessage": Data(payload.utf8), "inputCorrectionLevel": "M"
            ])
            if let output = filter?.outputImage {
                image = CIContext().createCGImage(output, from: output.extent)
            }
        }
    }
}

private struct PairingPanel: View {
    @ObservedObject var model: ReceiverModel

    @State private var showQR = false

    private var code: String { model.isRunning ? model.pin : "------" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelHeader(icon: "iphone.radiowaves.left.and.right", title: "Pairing")

            VStack(alignment: .leading, spacing: 2) {
                Text("PAIRING CODE")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 10) {
                    Text(code)
                        .font(.system(size: 52, weight: .semibold, design: .monospaced))
                        .tracking(6)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color(hex: 0x9BE8DF)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Button { showQR = true } label: {
                        Image(systemName: "qrcode").font(.title2)
                    }
                    .accessibilityLabel("Show pairing QR code")
                    .help("Show pairing QR code")
                    .disabled(!model.isRunning || code.count != 6 || model.localAddress == "Unavailable")
                    .popover(isPresented: $showQR) {
                        PairingQRView(payload: "kishi://pair/\(model.localAddress)/\(code)")
                    }
                }
                .onChange(of: code) { _ in showQR = false }
            }

            Text("Tap the QR icon beside the pairing code on the phone, or enter the address and code. Then tap Connect.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Color.white.opacity(0.08))

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("MAC IP ADDRESS")
                    HStack(spacing: 8) {
                        Text(model.localAddress)
                            .font(.system(size: 14.5, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                        Button(action: model.copyAddress) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.localAddress == "Unavailable")
                        .help("Copy address")
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("PORT")
                    Text("\(ReceiverServer.port)")
                        .font(.system(size: 14.5, weight: .medium, design: .monospaced))
                }
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(model.isConnected ? Color.green : Color.white.opacity(0.25))
                    .frame(width: 7, height: 7)
                Text(model.statusDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .panel()
    }
}

// MARK: - Receiver mode

private struct ReceiverPanel: View {
    @ObservedObject var model: ReceiverModel

    private var gamepadStatusText: String {
        if model.hasGamepad {
            return "Kishi Wi-Fi Gamepad is published to macOS."
        }
        if model.selectedMode == .monitor || model.gamepadError != nil {
            return "Input is visible here but games receive nothing."
        }
        return "Kishi Wi-Fi Gamepad will be published when the receiver starts."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(icon: "slider.horizontal.3", title: "Receiver")

                Picker(
                    "Mode",
                    selection: Binding(
                        get: { model.selectedMode },
                        set: { model.selectMode($0) }
                    )
                ) {
                    ForEach(ReceiverMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .font(.system(size: 13.5))

                Text(model.selectedMode.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: model.hasGamepad ? "checkmark.circle.fill" : "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(model.hasGamepad ? Color.green : Color.orange)
                    Text(gamepadStatusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = model.gamepadError {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Virtual gamepad unavailable", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.orange.opacity(0.07))
                    )
                } else if model.selectedMode == .gamepad, !model.isRunning {
                    Text("The virtual gamepad is created when the receiver starts.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .panel()
    }
}

// MARK: - Activity

private struct ActivityPanel: View {
    @ObservedObject var model: ReceiverModel
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PanelHeader(icon: "terminal", title: "Activity")
                Spacer()
                Button("Clear", action: model.clearLogs)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .disabled(model.logs.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(model.logs) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Text(timeFormatter.string(from: entry.date))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 82, alignment: .leading)
                                Text(entry.message)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(11)
                }
                .frame(maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                )
                .onChange(of: model.logs.count) { _ in
                    if let id = model.logs.last?.id {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(18)
        .panel()
    }

    private func color(for level: ReceiverLogLevel) -> Color {
        switch level {
        case .info: return Color.white.opacity(0.62)
        case .success: return Color(hex: 0x74E0C8)
        case .warning: return Color(hex: 0xF5C56B)
        case .error: return Color(hex: 0xFF8A8A)
        }
    }
}

// MARK: - Shared design

struct PanelHeader: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x67D9CB))
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct FieldLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(1)
            .foregroundStyle(.tertiary)
    }
}

private struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x090D17), Color(hex: 0x0E1728), Color(hex: 0x0A111F)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(hex: 0x2DD4BF).opacity(0.13))
                .frame(width: 520, height: 520)
                .blur(radius: 130)
                .offset(x: -330, y: -280)

            Circle()
                .fill(Color(hex: 0x6366F1).opacity(0.11))
                .frame(width: 460, height: 460)
                .blur(radius: 130)
                .offset(x: 380, y: 330)
        }
        .ignoresSafeArea()
    }
}

private struct PanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.042))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.11), Color.white.opacity(0.035)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.22), radius: 16, y: 8)
            )
    }
}

extension View {
    func panel() -> some View {
        modifier(PanelModifier())
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
