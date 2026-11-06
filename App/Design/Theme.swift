import AppKit
import SwiftUI
import Theming

/// Shared look: data colors, numerals and card geometry, all read from `ThemeStore` so the whole
/// interface follows the chosen theme, style, fonts and text size.
enum Theme {
    static var blue: Color { ThemeStore.shared.color(.blue) }
    static var cyan: Color { ThemeStore.shared.color(.cyan) }
    static var mint: Color { ThemeStore.shared.color(.mint) }
    static var amber: Color { ThemeStore.shared.color(.amber) }
    static var rose: Color { ThemeStore.shared.color(.rose) }
    static var violet: Color { ThemeStore.shared.color(.violet) }
    static var orange: Color { ThemeStore.shared.color(.orange) }
    static var slate: Color { ThemeStore.shared.color(.slate) }
    static var accent: Color { ThemeStore.shared.color(.accent) }

    static var cardRadius: CGFloat { ThemeStore.shared.isPixel ? 6 : 12 }
    /// Big numbers use the display face (pixel font by default) with fixed-width digits, so values
    /// don't jitter as they change.
    static var numeral: Font { .display(24).monospacedDigit() }
    static var mediumNumeral: Font { .display(19).monospacedDigit() }
    static var smallNumeral: Font { ThemeStore.shared.isPixel ? .display(13).monospacedDigit() : .display(13).monospacedDigit() }
    static var label: Font { .mh(size: 11, weight: .medium) }
    /// Card and section headings.
    static var heading: Font { .display(15) }
}

/// Surface and text colors of the current theme.
enum Palette {
    static var base: Color { ThemeStore.shared.color(.base) }
    static var card: Color { ThemeStore.shared.color(.card) }
    static var inset: Color { ThemeStore.shared.color(.inset) }
    static var raised: Color { ThemeStore.shared.color(.raised) }
    static var stroke: Color { ThemeStore.shared.color(.stroke) }
    static var hairline: Color { ThemeStore.shared.color(.hairline) }
    static var text: Color { ThemeStore.shared.color(.text) }
    static var textMuted: Color { ThemeStore.shared.color(.textMuted) }
    static var textFaint: Color { ThemeStore.shared.color(.textFaint) }
}

/// An interface icon by asset name (`px.<id>`). What it draws follows Settings → Appearance →
/// Icons: a hand-replaced image, an icon pack, system symbols or the built-in pixel art.
struct PixelIcon: View {
    let name: String
    var size: CGFloat = 16
    /// Set only when the icon carries meaning; decorative icons stay hidden from VoiceOver.
    var label: LocalizedStringKey? = nil

    @ViewBuilder var body: some View {
        let image = picture.frame(width: size, height: size)
        if let label {
            image.accessibilityLabel(label)
        } else {
            image.accessibilityHidden(true)
        }
    }

    @ViewBuilder private var picture: some View {
        switch ThemeStore.shared.icon(IconCatalog.id(forAssetName: name)) {
        case .asset(let asset):
            Image(asset).interpolation(.none).resizable()
        case .image(let img, let pixelated):
            Image(nsImage: img).interpolation(pixelated ? .none : .high).resizable().aspectRatio(contentMode: .fit)
        case .symbol(let symbol, let color):
            Image(systemName: symbol).resizable().scaledToFit().fontWeight(.semibold).foregroundStyle(color)
                .padding(size * 0.08)
        }
    }
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface()
    }
}

/// Card background: in the pixel style a notched block with a 2 pt border and a hard drop shadow
/// (like a game UI window); otherwise a rounded card with a hairline border.
struct SurfaceBackground: ViewModifier {
    var fill: Color = Palette.card
    func body(content: Content) -> some View {
        let shape = SurfaceShape(cornerRadius: Theme.cardRadius)
        if ThemeStore.shared.isPixel {
            content
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(Palette.stroke, lineWidth: 2))
                .background(shape.fill(Color.black.opacity(0.28)).offset(x: 0, y: 3))
        } else {
            content
                .background(fill, in: shape)
                .overlay(shape.strokeBorder(Palette.stroke, lineWidth: 1))
        }
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardStyle(padding: padding)) }
    func surface(_ fill: Color = Palette.card) -> some View { modifier(SurfaceBackground(fill: fill)) }
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
                Text(section.title).font(.display(22)).foregroundStyle(Palette.text)
                if let subtitle { Text(subtitle).font(.mhCallout).foregroundStyle(Palette.textMuted) }
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
            Text(title).font(.display(22, weight: .bold)).foregroundStyle(Palette.text)
            Text(message).font(.mhCallout).foregroundStyle(Palette.textMuted).multilineTextAlignment(.center).frame(maxWidth: 440)
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
            .font(.mhCaption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: SurfaceShape.capsule)
            .foregroundStyle(color)
    }
}
