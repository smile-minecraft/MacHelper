import Foundation
import Testing
@testable import DiskScan

@Suite struct ByteSizeFormatTests {
    private let german = Locale(identifier: "de_DE")
    private let english = Locale(identifier: "en_US")

    /// A scan starts at zero bytes and an empty folder is zero bytes: both must read as a number.
    /// `ByteCountFormatter`'s convenience call printed "Zero KB" there, which a size badge, a
    /// table cell and a scanning line all showed as if it were a measured figure.
    @Test func zeroIsANumberNotAWord() {
        let zero = ByteSize.formatted(0)
        #expect(zero != ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
        #expect(zero.contains("0"))
        #expect(!zero.lowercased().contains("zero"))
        // The same rule applies to a rate and to the menu bar's compact form.
        #expect(ByteSize.amount(0) == "0 B")
        #expect(ByteSize.compact(0) == "0B")
    }

    /// A negative size only ever comes from a subtraction that went wrong; showing "-1 KB" hides
    /// that, so it reads as no space at all.
    @Test func negativeSizesReadAsZero() {
        #expect(ByteSize.formatted(-1) == ByteSize.formatted(0))
        #expect(ByteSize.formatted(-1_048_576) == ByteSize.formatted(0))
        #expect(ByteSize.amount(-42) == ByteSize.amount(0))
        #expect(ByteSize.compact(-42) == ByteSize.compact(0))
    }

    /// A byte count from `UInt64` that does not fit an `Int64` saturates instead of wrapping to a
    /// negative (and therefore to zero).
    @Test func sizesTooLargeForInt64Saturate() {
        #expect(ByteSize.formatted(UInt64.max) == ByteSize.formatted(Int64.max))
        #expect(ByteSize.formatted(UInt64(Int64.max) + 1) == ByteSize.formatted(Int64.max))
    }

    /// The amount formatter feeds live readings. A rate divided by a zero interval is infinite and
    /// used to divide forever; it must fall back to zero and return.
    @Test func nonFiniteAmountsFallBackToZero() {
        #expect(ByteSize.amount(.infinity) == "0 B")
        #expect(ByteSize.amount(-.infinity) == "0 B")
        #expect(ByteSize.amount(.nan) == "0 B")
        #expect(ByteSize.compact(.infinity) == "0B")
    }

    /// Under a kilobyte there is no fraction of a byte, and a three-digit figure has no decimals.
    @Test func amountKeepsItsPromisedPrecision() {
        #expect(ByteSize.amount(961, locale: english) == "961 B")
        #expect(ByteSize.amount(12_400_000, locale: english) == "11.8 MB")
        #expect(ByteSize.amount(2_600_000_000, locale: english) == "2.4 GB")
    }

    /// A rate or a size is a number for the person's locale too: a German Mac reads a decimal
    /// comma, and the surrounding text already uses one.
    @Test func amountsUseTheLocaleDecimalSeparator() {
        #expect(ByteSize.amount(12_400_000, locale: german) == "11,8 MB")
        #expect(ByteSize.amount(2_600_000_000, locale: german) == "2,4 GB")
        #expect(ByteSize.compact(1536, locale: german) == "1,5K")
        #expect(ByteSize.compact(1536, locale: english) == "1.5K")
    }

    /// RAM is counted in binary units, so 32 GiB reads "32 GB" like Activity Monitor rather than
    /// the 34.36 GB a file-size formatter would print for the same bytes.
    @Test func memoryStyleUsesBinaryUnits() {
        let gib32 = UInt64(32) * 1024 * 1024 * 1024
        let memory = ByteSize.formatted(gib32, style: .memory)
        #expect(memory.contains("32"))
        #expect(memory != ByteSize.formatted(gib32, style: .file))
    }
}
