import AppKit
import SwiftUI

/// One set of timing curves for the whole interface, so every movement feels like the same app.
///
/// - `standard`: a page or a section changes what it shows (scan → results, a page switch).
/// - `snappy`: a selection moves (tabs, chips, a sliding highlight).
/// - `fade`: one version of an area replacing another in place.
/// - `hover` / `press`: pointer feedback; short enough that it never trails the pointer.
/// - `meter`: gauges gliding to a new reading.
///
/// With Reduce Motion everything that moves or scales is dropped; plain fades stay (they carry no
/// motion), so hover feedback still reads.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Content swaps: critically damped, so nothing overshoots.
    static var standard: Animation? { reduced ? nil : .smooth(duration: 0.34) }
    /// Selection highlights: quick with a hint of follow-through.
    static var snappy: Animation? { reduced ? nil : .snappy(duration: 0.28, extraBounce: 0.04) }
    /// Cross-fades between two versions of the same area (another app picked, another chart
    /// type). Kept with Reduce Motion: nothing moves.
    static let fade: Animation = .easeInOut(duration: 0.2)
    /// Color and opacity on hover. Kept with Reduce Motion: it is a fade, not a movement.
    static let hover: Animation = .easeOut(duration: 0.16)
    /// Press-down scale on buttons and tiles.
    static var press: Animation? { reduced ? nil : .spring(duration: 0.22, bounce: 0.2) }

    /// Gauges glide to a new value in the standard look, jump in the pixel look (it is drawn in
    /// whole blocks), and stand still with Reduce Motion.
    static func meter(_ duration: Double) -> Animation? {
        reduced || ThemeStore.shared.isPixel ? nil : .smooth(duration: duration)
    }

    /// One state of a page replacing another (start screen → scanning → results): the new
    /// state fades in, settling up a few points, while the old one fades out in place.
    static var swap: AnyTransition {
        reduced ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.995, anchor: .top)),
            removal: .opacity)
    }

    /// A whole page coming in after a sidebar switch. The old page leaves at once, so two heavy
    /// pages are never composited on top of each other mid-fade (that double exposure is what
    /// made page switches stutter); the new one fades in and rises a few points.
    static var pageIn: AnyTransition {
        reduced ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .identity)
    }
}

extension View {
    /// Animates whatever this view shows when `value` changes, with the shared content curve.
    /// Pair with `.transition(Motion.swap)` on the views that come and go.
    func animatesStates<V: Equatable>(_ value: V) -> some View {
        animation(Motion.standard, value: value)
    }
}
