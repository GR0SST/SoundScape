import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.055, green: 0.059, blue: 0.066)
    static let appBackground = Color(red: 0.047, green: 0.050, blue: 0.056)
    static let elevated = Color(red: 0.075, green: 0.079, blue: 0.088)
    static let surface = Color(red: 0.088, green: 0.093, blue: 0.103)
    static let surfaceHover = Color(red: 0.108, green: 0.114, blue: 0.126)
    static let panelBackground = Color(red: 0.082, green: 0.086, blue: 0.096)
    static let line = Color.white.opacity(0.10)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.38)
}

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 10
    var border: Color = AppTheme.line

    func body(content: Content) -> some View {
        content
            .background(AppTheme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 10, border: Color = AppTheme.line) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, border: border))
    }
}

struct SoundScapeLogo: View {
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(DemoContent.cyan.opacity(0.88))

            Image(systemName: "waveform")
                .font(.system(size: size * 0.43, weight: .bold))
                .foregroundStyle(Color(red: 0.04, green: 0.09, blue: 0.11))
        }
        .frame(width: size, height: size)
    }
}

struct StatusPill: View {
    let label: String
    let color: Color

    init(status: SessionStatus) {
        label = status.rawValue
        switch status {
        case .running:
            color = DemoContent.mint
        case .ready:
            color = DemoContent.cyan
        case .draft:
            color = AppTheme.secondaryText
        }
    }

    init(label: String, color: Color) {
        self.label = label
        self.color = color
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            Text(label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(color)
    }
}

struct OutputLevelMeter: View {
    let levelDB: Double
    let isRunning: Bool
    let color: Color

    @State private var displayedLevel: CGFloat = 0

    private let profile: [CGFloat] = [
        0.30, 0.52, 0.76, 0.46, 0.88, 0.62, 1.00,
        0.72, 0.90, 0.54, 0.78, 0.40, 0.60, 0.28
    ]

    var body: some View {
        ZStack {
            liveWave
                .opacity(isRunning ? 1 : 0)
                .scaleEffect(
                    x: isRunning ? 1 : 0.22,
                    y: isRunning ? 1 : 0.10
                )

            restingDots
                .opacity(isRunning ? 0 : 1)
                .scaleEffect(isRunning ? 0.72 : 1)
        }
        .frame(width: isRunning ? 86 : 30, height: 28)
        .animation(
            .spring(response: 0.34, dampingFraction: 0.78),
            value: isRunning
        )
        .onAppear {
            displayedLevel = isRunning ? normalizedLevel : 0
        }
        .onChange(of: levelDB) { _, _ in
            guard isRunning else { return }
            withAnimation(.spring(response: 0.14, dampingFraction: 0.68)) {
                displayedLevel = normalizedLevel
            }
        }
        .onChange(of: isRunning) { _, running in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                displayedLevel = running ? normalizedLevel : 0
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Output signal")
        .accessibilityValue(
            isRunning
                ? String(format: "%.1f decibels", levelDB)
                : "Flow stopped"
        )
    }

    private var liveWave: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(profile.enumerated()), id: \.offset) { index, shape in
                    let ripple = CGFloat(
                        0.90 + 0.10 * sin(time * 7.2 + Double(index) * 0.82)
                    )
                    let height = max(
                        3,
                        3 + displayedLevel * (5 + shape * 18) * ripple
                    )

                    Capsule()
                        .fill(
                            color.opacity(
                                0.38 + 0.62 * Double(displayedLevel)
                            )
                        )
                        .frame(width: 3, height: height)
                }
            }
        }
        .frame(width: 86, height: 28)
    }

    private var restingDots: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .fill(
                        AppTheme.tertiaryText.opacity(
                            index == 2 ? 0.90 : (index.isMultiple(of: 2) ? 0.48 : 0.68)
                        )
                    )
                    .frame(width: 3, height: 3)
            }
        }
    }

    private var normalizedLevel: CGFloat {
        guard isRunning else { return 0 }
        let linear = min(max((levelDB + 80) / 70, 0), 1)
        return CGFloat(pow(linear, 0.56))
    }
}
