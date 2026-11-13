#!/bin/bash
# Runs the network-details section tests in a throwaway SwiftPM package.
#
# The package is assembled from copies of the network source, the reviewed presentation view and
# the section under test, so the manifest has no `.package(url:)` entry and SwiftPM has nothing to
# fetch. The shared design system is replaced by a small stub (see TestSupport.swift below) so the
# test never reads ThemeStore, user preferences, icon packs, the app or the helper. Every snapshot
# is synthetic; nothing calls getifaddrs, sysctl, SystemConfiguration or the network.
#
# The active toolchain must be able to parse Package.swift. Set DEVELOPER_DIR to a complete Xcode
# when the command-line tools alone are selected:
#   DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer Tests/UI/run-network-details-section-tests.sh
#
# Usage:
#   Tests/UI/run-network-details-section-tests.sh
#
# The scratch package is created under TMPDIR by default. Set MACHELPER_TEST_SCRATCH_ROOT when the
# default volume is short on space:
#   MACHELPER_TEST_SCRATCH_ROOT=/path/with/space Tests/UI/run-network-details-section-tests.sh
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

scratch_root="${MACHELPER_TEST_SCRATCH_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$scratch_root"
work="$(mktemp -d "$scratch_root/machelper-network-details-section-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Keep every write SwiftPM and the tests make inside this throwaway folder.
export HOME="$work/home"
export TMPDIR="$work/tmp"
echo "isolated test package: $work (HOME and TMPDIR are inside it)"
mkdir -p "$HOME" "$TMPDIR" \
         "$work/Sources/Metrics" \
         "$work/Sources/NetworkDetailsFeature" \
         "$work/Tests/NetworkDetailsSectionTests"

cp "$root/Sources/Metrics/NetworkDetails.swift" "$work/Sources/Metrics/NetworkDetails.swift"
# The model reuses the one NET_RT_IFLIST2 parser in Network.swift; compiling the real file keeps
# the test on the same code path instead of copying the parser.
cp "$root/Sources/Metrics/Network.swift" "$work/Sources/Metrics/Network.swift"
cp "$root/App/Monitor/NetworkDetailsContent.swift" "$work/Sources/NetworkDetailsFeature/NetworkDetailsContent.swift"
cp "$root/App/Monitor/NetworkDetailsSection.swift" "$work/Sources/NetworkDetailsFeature/NetworkDetailsSection.swift"
cp "$here/NetworkDetailsSectionTests.swift" "$work/Tests/NetworkDetailsSectionTests/NetworkDetailsSectionTests.swift"

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

extension Font {
    static func mh(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size, weight: weight, design: design)
    }
}
EOF

cat > "$work/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetworkDetailsSectionIsolatedTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Metrics"),
        .target(name: "NetworkDetailsFeature", dependencies: ["Metrics"]),
        .testTarget(
            name: "NetworkDetailsSectionTests",
            dependencies: ["NetworkDetailsFeature", "Metrics"]
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
echo "manifest check: no remote package dependencies"

swift test --package-path "$work" \
    --disable-automatic-resolution \
    --filter 'NetworkDetailsSectionTests'
