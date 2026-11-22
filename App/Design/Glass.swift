import SwiftUI

/// Liquid Glass, used only where macOS itself would use it: controls and bars that float above
/// content (the selection pill of a tab strip, the action bar under a list, header buttons).
/// Cards, charts and readings stay solid so numbers keep their contrast.
///
/// Glass needs macOS 26 and the smooth style; the pixel style keeps its flat blocks and hard
/// shadows, and older systems keep the solid look. Reduce Transparency and Increase Contrast are
/// handled by the system material itself.
enum LiquidGlass {
    static var isAvailable: Bool {
        if #available(macOS 26, *) { return !ThemeStore.shared.isPixel }
        return false
    }
}

extension View {
    /// Liquid Glass behind this view in `shape`, or `fallback` where glass isn't used.
    /// Apply after padding and frame, like any background.
    @ViewBuilder
    func glassSurface<S: Shape, Fallback: View>(
        in shape: S, tint: Color? = nil, interactive: Bool = false,
        @ViewBuilder fallback: (Self) -> Fallback
    ) -> some View {
        if #available(macOS 26, *), !ThemeStore.shared.isPixel {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            fallback(self)
        }
    }
}

extension EnvironmentValues {
    /// Cards drawn with `.surface()` become Liquid Glass panes (tinted with their fill, lifted by
    /// a soft shadow) instead of solid. Set by translucent containers such as the menu bar panel;
    /// ignored without Liquid Glass and in the pixel style.
    @Entry var frostedSurfaces = false
    /// True inside a glass card: section headers drop their hairlines and sit at the card's
    /// leading edge, because the card itself already separates the section.
    @Entry var insideGlassCard = false
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
            HStack(spacing: 12) { content }
                .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 9)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous)) { $0 }
                .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 6)
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
