import AppKit
import SwiftUI

// Test-only stand-ins for DiskIOSection's display dependencies, used only by the isolated
// verification package (see run-disk-activity-model-tests.sh). The production visual tools
// stay unchanged; here the section compiles against minimal substitutes so the unmodified
// production sources can mount headlessly. Do not reuse these elsewhere.

enum Palette {
    static let base = Color(red: 0.05, green: 0.05, blue: 0.06)
    static let card = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let inset = Color(red: 0.13, green: 0.13, blue: 0.14)
    static let text = Color(red: 0.93, green: 0.93, blue: 0.93)
    static let textMuted = Color(red: 0.55, green: 0.55, blue: 0.58)
    static let textFaint = Color(red: 0.38, green: 0.38, blue: 0.40)
    static let stroke = Color(red: 0.22, green: 0.22, blue: 0.23)
}

enum Theme {
    static let blue = Color(red: 0.35, green: 0.55, blue: 1.0)
    static let rose = Color(red: 0.95, green: 0.35, blue: 0.42)
}

extension Font {
    static func mh(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size, weight: weight)
    }

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
}

extension View {
    func surface(_ fill: Color = Palette.card) -> some View {
        background(fill)
    }
}

/// Title row of a panel card: title, optional subtitle, then trailing content.
struct PanelCardHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.mh(size: 13.5, weight: .bold)).foregroundStyle(Palette.text)
            if let subtitle {
                Text(subtitle).font(.mh(size: 10.5)).foregroundStyle(Palette.textFaint)
            }
            Spacer(minLength: 4)
            trailing
        }
        .accessibilityAddTraits(.isHeader)
    }
}

extension PanelCardHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct Meter: View {
    let fraction: Double
    var color: Color = Theme.blue

    var body: some View {
        Capsule().fill(color.opacity(0.7)).frame(height: 8)
    }
}

/// Placeholder rows shown while the first sample arrives.
struct SkeletonRows: View {
    var count = 5

    var body: some View {
        VStack(spacing: 9) {
            ForEach(0..<count, id: \.self) { _ in
                Capsule().frame(height: 10)
            }
        }
        .foregroundStyle(Palette.inset)
    }
}

/// One shared blank icon; the isolated package never looks up real app icons.
enum ProcessIcon {
    static func icon(appPath: String?) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20))
    }
}

enum Fmt {
    static func percent(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "\(Int((v * 100).rounded()))%"
    }

    static func rateLong(_ bytesPerSecond: Double?) -> String {
        guard let b = bytesPerSecond else { return "–" }
        return "\(Int(b))B/s"
    }
}
