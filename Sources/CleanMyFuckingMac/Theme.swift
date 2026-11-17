import SwiftUI

enum Theme {
    static let pink = Color(red: 1.0, green: 0.30, blue: 0.55)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.27)
    static let violet = Color(red: 0.55, green: 0.36, blue: 1.0)
    static let mint = Color(red: 0.30, green: 0.90, blue: 0.72)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)

    static let accent = LinearGradient(colors: [pink, orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let background = LinearGradient(
        colors: [Color(red: 0.11, green: 0.06, blue: 0.22), Color(red: 0.16, green: 0.08, blue: 0.30),
                 Color(red: 0.05, green: 0.09, blue: 0.22)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let secondaryText = Color.white.opacity(0.6)

    /// Stable colours for treemap cells and list bars.
    static let palette: [Color] = [
        pink, orange, violet, mint, Color(red: 0.30, green: 0.65, blue: 1.0), Color(red: 1.0, green: 0.82, blue: 0.30),
        Color(red: 0.85, green: 0.40, blue: 0.95), Color(red: 0.40, green: 0.85, blue: 0.95),
    ]
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.08)))
    }
}

struct AccentButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(destructive ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.accent), in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Screen title with a subtitle and trailing actions.
struct PageHeader<Actions: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            actions
        }
    }
}

/// Centered placeholder for screens with nothing to show yet.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(message).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RingGauge: View {
    let fraction: Double
    var lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: fraction)
        }
    }
}

struct CheckBox: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.35)))
        }
        .buttonStyle(.plain)
    }
}

/// App logo: a disk-usage ring with a lightning bolt.
struct LogoView: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Theme.pink, Theme.violet, Color(red: 0.16, green: 0.12, blue: 0.5)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(RadialGradient(colors: [.white.opacity(0.28), .clear], center: .topLeading,
                                     startRadius: 0, endRadius: size * 0.9))
            Circle()
                .trim(from: 0, to: 0.70)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: size * 0.60, height: size * 0.60)
            Circle()
                .trim(from: 0.78, to: 0.94)
                .stroke(Theme.orange, style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: size * 0.60, height: size * 0.60)
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.27, weight: .black))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

extension Date {
    var shortLabel: String { formatted(date: .abbreviated, time: .omitted) }
}

func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}
