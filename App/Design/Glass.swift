import SwiftUI
import Theming

/// Liquid Glass, used where macOS itself would use it: controls and bars that float above content
/// (the selection pill of a tab strip, the action bar under a list, header buttons) and, inside
/// the menu bar panel, the cards.
///
/// Whether it is drawn follows Settings → Appearance → Material (`ThemeStore.material`): it needs
/// the Liquid Glass material, macOS 26 and the smooth style, and gives way to the frosted look
/// with Increase Contrast and to solid surfaces with Reduce Transparency. Glass is always tinted
/// with a theme token (bright in light, deep in dark) so ink never depends on the wallpaper.
enum LiquidGlass {
    static var isAvailable: Bool { ThemeStore.shared.material == .liquidGlass }
}

extension View {
    /// Liquid Glass behind this view in `shape`, or `fallback` where glass isn't used.
    /// Apply after padding and frame, like any background. Without a `tint` the glass takes the
    /// control tint, so a glyph on it stays readable over any wallpaper.
    @ViewBuilder
    func glassSurface<S: Shape, Fallback: View>(
        in shape: S, tint: Color? = nil, interactive: Bool = false,
        @ViewBuilder fallback: (Self) -> Fallback
    ) -> some View {
        if #available(macOS 26, *), LiquidGlass.isAvailable {
            modifier(ThemedGlass(shape: shape, tint: tint ?? Palette.glassControlTint, interactive: interactive))
        } else {
            fallback(self)
        }
    }
}

/// Glass adapts what sits on it to the brightness of the backdrop (dark ink over a bright
/// wallpaper, light over a dark one). The theme already picked the ink and the tint, so the
/// content keeps the color scheme of the view around the glass.
@available(macOS 26, *)
private struct ThemedGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color
    let interactive: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, scheme)
            .glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
    }
}

extension EnvironmentValues {
    /// Set by translucent containers such as the menu bar panel: cards drawn with `.surface()`
    /// follow the material there (raised opaque cards when frosted, tinted glass panes with
    /// Liquid Glass). Ignored in the pixel style and with the solid material.
    @Entry var frostedSurfaces = false
    /// True inside a panel card: section headers drop their hairlines and sit at the card's
    /// leading edge, because the card itself already separates the section.
    @Entry var insideGlassCard = false
}

/// The wash behind a translucent container (the menu bar panel): opaque theme surface when solid,
/// a light scrim over the system material when frosted, a stronger one under Liquid Glass. Both
/// scrims are bright in light and deep in dark, and opaque enough that a white or black wallpaper
/// never decides how text reads (see `SurfaceTokens`).
struct PanelBackdrop: View {
    var body: some View {
        switch ThemeStore.shared.material {
        case .solid: ThemeStore.shared.isSoft ? Palette.base : Palette.card
        case .frosted: Palette.frostedPanelScrim
        case .liquidGlass: Palette.glassPanelScrim
        }
    }
}

/// The bar with a selection total and the main action under a list or a result.
///
/// With Liquid Glass it floats as a rounded glass pane a few points above the bottom edge, and the
/// content scrolls on underneath it (attach it with `actionBar(_:)`). Otherwise it is the flat
/// strip under a hairline that the app always had.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if LiquidGlass.isAvailable {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            HStack(spacing: 12) { content }
                .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 9)
                .glassSurface(in: shape, tint: Palette.glassCardTint) { $0 }
                .overlay(shape.strokeBorder(Palette.glassCardBorder, lineWidth: 1))
                .shadow(color: Palette.glassShadow, radius: 8, y: 3)
                .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 6)
        } else if ThemeStore.shared.isSoft {
            HStack(spacing: 12) { content }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Palette.base)
                .overlay(alignment: .top) {
                    VStack(spacing: 0) {
                        Rectangle().fill(Palette.softShadow.opacity(0.35)).frame(height: 1)
                        Rectangle().fill(Palette.softHighlight.opacity(0.75)).frame(height: 1)
                    }
                }
        } else {
            HStack(spacing: 12) { content }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Palette.card)
                .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }
    }
}

extension View {
    /// Pins an `ActionBar` to the bottom edge. Scroll views and lists inside this view inset their
    /// content by the bar's height, so the last row can still scroll clear of it; with glass the
    /// rows pass underneath the floating pane.
    func actionBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { ActionBar { content() } }
    }
}
