#!/bin/bash
# Runs the network-details view tests in a throwaway SwiftPM package.
#
# The package is assembled from copies of the production model and view plus the test file, so the
# manifest has no `.package(url:)` entry and SwiftPM has nothing to fetch. The shared design system
# is replaced by a small stub (see TestSupport.swift below) so the test never reads ThemeStore, user
# preferences, icon packs, the app or the helper. Every snapshot is synthetic; nothing calls
# getifaddrs, sysctl, SystemConfiguration or the network.
#
# The active toolchain must be able to parse Package.swift. Set DEVELOPER_DIR to a complete Xcode
# when the command-line tools alone are selected:
#   DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer Tests/UI/run-network-details-tests.sh
#
# Usage:
#   Tests/UI/run-network-details-tests.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    for candidate in /Applications/Xcode.app /Applications/Xcode-*.app /Volumes/Smile-Data/Applications/Xcode-*.app; do
        if [[ -d "$candidate/Contents/Developer" ]]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
if ! xcrun --find swift >/dev/null 2>&1; then
    echo "error: swift is unavailable; set DEVELOPER_DIR to an Xcode with the macOS SDK" >&2
    exit 1
fi
if ! xcrun --find xcstringstool >/dev/null 2>&1; then
    echo "error: xcstringstool is unavailable; set DEVELOPER_DIR to a complete Xcode" >&2
    exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/machelper-network-details-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Keep every write SwiftPM and the tests make inside this throwaway folder.
export HOME="$work/home"
export TMPDIR="$work/tmp"
echo "isolated test package: $work (HOME and TMPDIR are inside it)"
mkdir -p "$HOME" "$TMPDIR" \
         "$work/Sources/Metrics" \
         "$work/Sources/NetworkDetailsFeature" \
         "$work/Tests/NetworkDetailsTests/Resources/Localizations"

cp "$root/Sources/Metrics/NetworkDetails.swift" "$work/Sources/Metrics/NetworkDetails.swift"
# The model reuses the one NET_RT_IFLIST2 parser in Network.swift; compiling the real file keeps
# the test on the same code path instead of copying the parser.
cp "$root/Sources/Metrics/Network.swift" "$work/Sources/Metrics/Network.swift"
cp "$root/App/Monitor/NetworkDetailsContent.swift" "$work/Sources/NetworkDetailsFeature/NetworkDetailsContent.swift"
cp "$here/NetworkDetailsContentTests.swift" "$work/Tests/NetworkDetailsTests/NetworkDetailsContentTests.swift"
cp "$root/App/Resources/NetworkDetails.xcstrings" "$work/Tests/NetworkDetailsTests/Resources/NetworkDetails.xcstrings"

# Compile the real catalog into the test bundle so the tests can resolve every key through the
# same table name the view uses. The source catalog is copied too for the completeness check.
xcrun xcstringstool compile "$work/Tests/NetworkDetailsTests/Resources/NetworkDetails.xcstrings" \
    --output-directory "$work/Tests/NetworkDetailsTests/Resources/Localizations"

# The production view uses the app's shared visual language. These stubs keep that surface and
# replace the ThemeStore-backed implementation, which would otherwise read user preferences.
cat > "$work/Sources/NetworkDetailsFeature/TestSupport.swift" <<'EOF'
import AppKit
import SwiftUI

// Test-only stand-ins for the app design system. Only the look is replaced; the production view
// and display model are compiled unchanged.
enum Theme {
    static let accent = Color.accentColor
    static let blue = Color.blue
    static let cyan = Color.cyan
    static let mint = Color.green
    static let amber = Color.orange
    static let rose = Color.red
    static let violet = Color.purple
    static let slate = Color.gray
    static let orange = Color.orange
}

enum Palette {
    static let base = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let inset = Color(nsColor: .underPageBackgroundColor)
    static let raised = Color(nsColor: .controlBackgroundColor)
    static let stroke = Color(nsColor: .separatorColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let text = Color.primary
    static let textMuted = Color.secondary
    static let textFaint = Color.secondary.opacity(0.7)
}

struct SurfaceShape: InsettableShape {
    var cornerRadius: CGFloat
    var capsule = false
    private var insetAmount: CGFloat = 0

    init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        self.cornerRadius = cornerRadius
    }

    init(capsule: Bool) {
        cornerRadius = 0
        self.capsule = capsule
    }

    static var capsule: SurfaceShape { SurfaceShape(capsule: true) }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        if capsule { return Capsule(style: .continuous).path(in: r) }
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> SurfaceShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: SurfaceShape.capsule)
            .foregroundStyle(color)
    }
}

/// Simulates the app's text-size setting. The tests set it to a larger value to check wrapping;
/// production reads ThemeStore's textScale instead.
enum NetworkDetailsTestFontScale {
    nonisolated(unsafe) static var value: CGFloat = 1
}

extension Font {
    static func mh(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * NetworkDetailsTestFontScale.value, weight: weight, design: design)
    }
}
EOF

cat > "$work/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetworkDetailsIsolatedTests",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Metrics"),
        .target(name: "NetworkDetailsFeature", dependencies: ["Metrics"]),
        .testTarget(
            name: "NetworkDetailsTests",
            dependencies: ["NetworkDetailsFeature", "Metrics"],
            resources: [.copy("Resources")]
        ),
    ]
)
EOF

# Keep the isolation property explicit: a remote package would make resolution able to reach the
# network even though the flags below would try to stop it.
if grep -q '\.package(url:' "$work/Package.swift"; then
    echo "error: the isolated test manifest must not contain remote package dependencies" >&2
    exit 1
fi

swift test --package-path "$work" \
    --disable-automatic-resolution \
    --filter 'NetworkDetailsContentTests'
