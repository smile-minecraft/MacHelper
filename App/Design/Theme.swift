import AppKit
import SwiftUI

/// Shared look: section accents (matching the pixel palette), cards, pixel icons, numerals.
enum Theme {
    // Chart colors: desaturated (< 80 %) so they sit on neutral zinc instead of shouting.
    static let blue = Color(red: 0.36, green: 0.55, blue: 0.86)
    static let cyan = Color(red: 0.25, green: 0.66, blue: 0.74)
    static let mint = Color(red: 0.24, green: 0.66, blue: 0.48)
    static let amber = Color(red: 0.84, green: 0.62, blue: 0.25)
    static let rose = Color(red: 0.86, green: 0.39, blue: 0.43)
    static let violet = Color(red: 0.49, green: 0.55, blue: 0.70)   // slate-blue, not purple
    static let orange = Color(red: 0.86, green: 0.48, blue: 0.25)
    static let slate = Color(red: 0.58, green: 0.60, blue: 0.64)

    static let accent = Color(red: 0.24, green: 0.66, blue: 0.48)   // the one accent: emerald

    static let cardRadius: CGFloat = 12
    /// Numbers use a monospaced face: values don't jitter as they change, and it reads like a console.
    static let numeral = Font.system(size: 24, weight: .semibold, design: .monospaced)
    static let mediumNumeral = Font.system(size: 19, weight: .semibold, design: .monospaced)
    static let smallNumeral = Font.system(size: 13, weight: .semibold, design: .monospaced)
    static let label = Font.system(size: 11, weight: .medium)
}

/// Surface colors with their own light/dark values (a blue-tinted dark, like a console), so the app
/// doesn't read as stock gray.
enum Palette {
    // One neutral family (zinc) in both appearances.
    static let base = dynamic(light: 0xFAFAFA, dark: 0x111113)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x18181B)
    static let inset = dynamic(light: 0xF0F0F2, dark: 0x232327)
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x2C2C31)
    static let stroke = dynamic(light: 0x18181B, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.075)
    static let hairline = dynamic(light: 0x18181B, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.06)
    static let text = dynamic(light: 0x18181B, dark: 0xF4F4F5)
    static let textMuted = dynamic(light: 0x52525B, dark: 0xA1A1AA)
    static let textFaint = dynamic(light: 0x71717A, dark: 0x8B8B94)

    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

/// Pixel art from the asset catalog, scaled without smoothing.
struct PixelIcon: View {
    let name: String
    var size: CGFloat = 16
    /// Set only when the icon carries meaning; decorative icons stay hidden from VoiceOver.
    var label: LocalizedStringKey? = nil

    @ViewBuilder var body: some View {
        let image = Image(name).interpolation(.none).resizable().frame(width: size, height: size)
        if let label {
            image.accessibilityLabel(label)
        } else {
            image.accessibilityHidden(true)
        }
    }
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardStyle(padding: padding)) }
}

/// Title row shown at the top of every page.
struct PageHeader<Trailing: View>: View {
    let section: AppSection
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            PixelIcon(name: section.icon, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.title2.weight(.semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(section: AppSection, subtitle: String? = nil) {
        self.init(section: section, subtitle: subtitle) { EmptyView() }
    }
}

/// A cheap line chart for tiles: one Path, no axes, redrawn only when its values change.
struct AreaSparkline: View, Equatable {
    let values: [Double]
    var maxValue: Double?
    var color: Color
    var lineWidth: CGFloat = 1.4

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let top = max(maxValue ?? (values.max() ?? 1) * 1.15, 0.0001)
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(v / top, 1))))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.30), color.opacity(0.10)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// A centered pixel illustration with a title, message and actions (start pages, empty lists).
struct PixelEmptyState<Actions: View>: View {
    let art: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            PixelIcon(name: art, size: 128)
            Text(title).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            actions.padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pixel art that bobs gently while work is in progress (respects Reduce Motion).
struct ScanningArt: View {
    let art: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PixelIcon(name: art, size: 96)
            .phaseAnimator(reduceMotion ? [0.0] : [0.0, -6.0]) { view, y in view.offset(y: y) }
                animation: { _ in .easeInOut(duration: 0.6) }
    }
}

/// Small rounded label, e.g. a status.
struct Pill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
