import SwiftUI

struct InputPanel: View {
    @ObservedObject var model: ReceiverModel

    private let accent = Color(hex: 0x2DD4BF)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PanelHeader(icon: "waveform.path.ecg", title: "Live input")
                Spacer()
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.isConnected ? (model.isStalled ? Color.orange : Color.green) : Color.white.opacity(0.2))
                        .frame(width: 7, height: 7)
                    Text(model.isConnected ? (model.isStalled ? "Idle" : "Streaming") : "No phone")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 24) {
                StickView(
                    label: "Left stick",
                    x: model.input.thumbLX,
                    y: model.input.thumbLY,
                    active: model.isConnected && !model.isStalled,
                    accent: accent
                )

                VStack(spacing: 11) {
                    TriggerBar(
                        label: "LT",
                        value: model.input.leftTrigger,
                        active: model.isConnected && !model.isStalled,
                        accent: accent
                    )
                    TriggerBar(
                        label: "RT",
                        value: model.input.rightTrigger,
                        active: model.isConnected && !model.isStalled,
                        accent: accent
                    )

                    HStack(spacing: 8) {
                        Text("D-PAD")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 2)
                        HatIndicator(flags: model.input.flags, active: model.isConnected && !model.isStalled, accent: accent)
                    }
                }
                .frame(maxWidth: .infinity)

                StickView(
                    label: "Right stick",
                    x: model.input.thumbRX,
                    y: model.input.thumbRY,
                    active: model.isConnected && !model.isStalled,
                    accent: accent
                )
            }

            Divider().overlay(Color.white.opacity(0.08))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 6),
                spacing: 9
            ) {
                ForEach(GamepadState.buttons, id: \.name) { button in
                    let pressed = model.input.pressedButtons & button.mask != 0
                    Text(button.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(pressed ? accent : Color.white.opacity(0.045))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(
                                    pressed ? accent.opacity(0.65) : Color.white.opacity(0.075),
                                    lineWidth: 1
                                )
                        )
                        .foregroundStyle(pressed ? Color.black.opacity(0.82) : Color.secondary)
                        .shadow(color: pressed ? accent.opacity(0.25) : .clear, radius: 5)
                }
            }
        }
        .padding(18)
        .panel()
    }
}

private struct StickView: View {
    let label: String
    let x: Int16
    let y: Int16
    let active: Bool
    let accent: Color

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                let travel = size * 0.34
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.035))
                    Circle()
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 1, height: size * 0.72)
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: size * 0.72, height: 1)
                    Circle()
                        .fill(active ? accent : Color.white.opacity(0.32))
                        .frame(width: 16, height: 16)
                        .offset(
                            x: CGFloat(x) / 32768 * travel,
                            y: -CGFloat(y) / 32768 * travel
                        )
                        .shadow(color: active ? accent.opacity(0.55) : .clear, radius: 7)
                }
                .padding(6)
                .frame(width: size, height: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 112, height: 112)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(x)  \(y)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct TriggerBar: View {
    let label: String
    let value: UInt8
    let active: Bool
    let accent: Color

    private var fraction: CGFloat { CGFloat(value) / 255 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.055))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.55), accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(3, geometry.size.width * fraction))
                        .opacity(active ? 1 : 0.35)
                }
            }
            .frame(height: 9)
        }
    }
}

private struct HatIndicator: View {
    let flags: UInt16
    let active: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 3) {
            arrow("arrow.up", mask: 0x0002)
            arrow("arrow.left", mask: 0x0008)
            arrow("arrow.down", mask: 0x0001)
            arrow("arrow.right", mask: 0x0004)
        }
    }

    private func arrow(_ name: String, mask: UInt16) -> some View {
        let pressed = flags & mask != 0
        return Image(systemName: name)
            .font(.system(size: 9.5, weight: .bold))
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(pressed && active ? accent : Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
            .foregroundStyle(pressed && active ? Color.black.opacity(0.8) : Color.secondary)
    }
}
