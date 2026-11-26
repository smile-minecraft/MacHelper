import Foundation

/// One place for every size MacHelper prints, so a figure in a list, in a chart caption and in an
/// alert always reads the same way.
///
/// `ByteCountFormatter`'s convenience call — `string(fromByteCount:countStyle:)` — formats zero as
/// "Zero KB". No scan ever measured a size in kilobytes called zero, and a scan page shows exactly
/// that for its first frames and for an empty folder. This type therefore formats zero as a
/// number, keeps a negative or non-finite value from becoming a size at all, and reuses one
/// formatter per style instead of building a new one (with its ICU state) on every row of every
/// redraw.
public enum ByteSize {
    /// The unit system of a size, matching what macOS shows in the same place.
    public enum Style: Sendable {
        /// Decimal units (1 KB = 1 000 bytes), as Finder counts file sizes.
        case file
        /// Binary units shown with decimal names (1 KB = 1 024 bytes), as Activity Monitor counts memory.
        case memory
    }

    /// A size for a list, a caption or an alert.
    ///
    /// A negative value reads as no space at all (a negative size only ever comes from a
    /// subtraction that went wrong, and "-1 KB" hides it), and a value too large for `Int64`
    /// saturates instead of wrapping to a negative — which would then read as zero.
    public static func formatted<T: BinaryInteger>(_ bytes: T, style: Style = .file) -> String {
        box(style).string(fromByteCount: max(Int64(clamping: bytes), 0))
    }

    /// A rate or a progress figure: "961 B", "12.4 MB", "2.6 GB" (no decimal under 1 KB, one
    /// decimal below 100). A non-finite value — a rate divided by a zero interval, say — reads as
    /// zero instead of "nan B" or an endless unit division.
    public static func amount(_ bytes: Double, locale: Locale = .current) -> String {
        var value = bytes.isFinite ? max(bytes, 0) : 0
        var unit = 0
        while value >= 1000, unit < decimalUnits.count - 1 {
            value /= 1024
            unit += 1
        }
        // Under 1 KB there is no fraction of a byte to show, and a three-digit figure would only
        // lose accuracy it has.
        let digits = unit == 0 || value >= 100
            ? String(format: "%.0f", locale: locale, value)
            : String(format: "%.1f", locale: locale, value)
        return "\(digits) \(decimalUnits[unit])"
    }

    /// The menu bar's very short rate: "940K", "12M", "1.2G". One decimal only below ten, so the
    /// menu bar item never changes width for a fraction nobody reads there.
    public static func compact(_ bytes: Double, locale: Locale = .current) -> String {
        var value = bytes.isFinite ? max(bytes, 0) : 0
        var unit = 0
        while value >= 1000, unit < compactUnits.count - 1 {
            value /= 1024
            unit += 1
        }
        let digits = value < 10 && unit > 0
            ? String(format: "%.1f", locale: locale, value)
            : String(format: "%.0f", locale: locale, value)
        return digits + compactUnits[unit]
    }

    private static let decimalUnits = ["B", "KB", "MB", "GB", "TB"]
    private static let compactUnits = ["B", "K", "M", "G", "T"]

    /// `ByteCountFormatter` is one object with mutable state; one per style, reached from the main
    /// thread and from a scan's background task, so each one takes a lock.
    private static let fileBox = FormatterBox(.file)
    private static let memoryBox = FormatterBox(.memory)

    private static func box(_ style: Style) -> FormatterBox { style == .file ? fileBox : memoryBox }

    private final class FormatterBox: @unchecked Sendable {
        private let lock = NSLock()
        private let formatter: ByteCountFormatter

        init(_ style: Style) {
            formatter = ByteCountFormatter()
            formatter.countStyle = style == .file ? .file : .memory
            // Zero is a size like any other: "0 bytes", never the nonnumeric "Zero KB".
            formatter.allowsNonnumericFormatting = false
            formatter.isAdaptive = true
            formatter.includesUnit = true
        }

        func string(fromByteCount bytes: Int64) -> String {
            lock.withLock { formatter.string(fromByteCount: bytes) }
        }
    }
}
