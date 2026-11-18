import AppKit
import Metrics
import SwiftUI

/// Busiest apps by the I/O the kernel attributes to their processes.
///
/// The numbers are process counters, not physical disk throughput: a read counts only when it
/// misses the page cache, a write counts when it is submitted, and processes this user may not
/// inspect are left out (and counted in the footnote) instead of being shown as zero.
struct DiskIOSection: View {
    let snapshot: ProcessDiskIOSnapshot?

    private static let visibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelCardHeader(title: "Disk I/O by app", subtitle: "Process I/O, not disk throughput")
            if let snapshot {
                let ranked = Self.ranked(snapshot)
                if ranked.isEmpty {
                    Text("No app read from or wrote to disk in the last few seconds.")
                        .font(.mh(size: 11)).foregroundStyle(Palette.textMuted)
                } else {
                    columnHeader
                }
                let shown = Array(ranked.prefix(Self.visibleRows))
                let rest = Array(ranked.dropFirst(Self.visibleRows))
                let total = ranked.reduce(0) { $0 + $1.rate }
                let restRate = rest.reduce(0) { $0 + $1.rate }
                let restRead: Double? = rest.allSatisfy { $0.read != nil } ? rest.reduce(0) { $0 + ($1.read ?? 0) } : nil
                let restWrite: Double? = rest.allSatisfy { $0.write != nil } ? rest.reduce(0) { $0 + ($1.write ?? 0) } : nil
                ForEach(shown) { item in
                    row(icon: ProcessIcon.icon(appPath: item.appPath), name: item.name,
                        detail: item.processCount > 1 ? String(localized: "\(item.processCount) processes") : nil,
                        read: item.read, write: item.write,
                        share: total > 0 ? item.rate / total : 0,
                        help: item.path ?? item.name)
                }
                if !rest.isEmpty {
                    row(icon: nil, name: String(localized: "Other apps (\(rest.count))"), detail: nil,
                        read: restRead, write: restWrite,
                        share: total > 0 ? restRate / total : 0, help: nil)
                }
                if snapshot.hiddenCount > 0 {
                    Text("\(snapshot.hiddenCount) processes couldn't be read (other users or system) and are not included.")
                        .font(.mh(size: 10)).foregroundStyle(Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SkeletonRows(count: 4).padding(.vertical, 4)
            }
        }
        .padding(12)
        .surface(Palette.base)
    }

    // MARK: Ranking

    /// One displayed row: an app group or a standalone process, ranked by the current interval.
    struct Row: Identifiable {
        var id: String
        var name: String
        var path: String?
        var appPath: String?
        var processCount: Int
        var read: Double?
        var write: Double?
        var total: UInt64

        var rate: Double { (read ?? 0) + (write ?? 0) }
    }

    /// Every group with I/O, busiest first. Before the first rates exist all rows have nil rates
    /// and are ordered by total bytes instead, so nothing is reported as zero.
    static func ranked(_ snapshot: ProcessDiskIOSnapshot) -> [Row] {
        snapshot.items
            .map { Row(id: $0.id, name: $0.name, path: $0.path, appPath: $0.appPath,
                       processCount: $0.processCount, read: $0.readBytesPerSecond,
                       write: $0.writeBytesPerSecond, total: $0.totalBytes) }
            .sorted { a, b in
                if a.rate != b.rate { return a.rate > b.rate }
                if a.total != b.total { return a.total > b.total }
                return a.id < b.id
            }
    }

    // MARK: Rows

    private var columnHeader: some View {
        HStack(spacing: 6) {
            Text("App").frame(maxWidth: .infinity, alignment: .leading)
            Text("Read").frame(width: 66, alignment: .trailing)
            Text("Write").frame(width: 66, alignment: .trailing)
            Text("Share").frame(width: 78, alignment: .trailing)
        }
        .font(.mh(size: 10.5, weight: .medium))
        .foregroundStyle(Palette.textFaint)
    }

    private func row(icon: NSImage?, name: String, detail: String?, read: Double?, write: Double?,
                     share: Double, help: String?) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 7) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "square.stack.3d.up").font(.mh(size: 12)).foregroundStyle(Palette.textMuted).frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: name).font(.mh(size: 12.5)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
                    if let detail { Text(verbatim: detail).font(.mh(size: 9.5)).foregroundStyle(Palette.textFaint).lineLimit(1) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: Fmt.rateLong(read)).frame(width: 66, alignment: .trailing)
                .foregroundStyle(Theme.blue)
            Text(verbatim: Fmt.rateLong(write)).frame(width: 66, alignment: .trailing)
                .foregroundStyle(Theme.rose)
            HStack(spacing: 5) {
                Meter(fraction: share, color: Theme.blue)
                    .frame(width: 32)
                Text(verbatim: Fmt.percent(share)).frame(width: 34, alignment: .trailing)
            }
            .frame(width: 78, alignment: .trailing)
        }
        .font(.display(11.5).monospacedDigit())
        .frame(height: 30)
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}
