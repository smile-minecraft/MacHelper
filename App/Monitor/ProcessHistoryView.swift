import Storage
import SwiftUI

/// Process rankings are re-read when the page is entered again; keep the last result for a
/// minute so the previous table appears at once while a newer one is read.
@MainActor
private enum ProcessHistoryCache {
    static var entries: [MonitorView.Range: (usage: ProcessUsageHistory, at: Date)] = [:]
    static let maxAge: TimeInterval = 60
}

/// Process rankings for the selected range, read from the shared minute history. Only each
/// minute's top ten by CPU and by memory are stored, so the caption explains that a missing
/// process may still have been running and each row shows how much of the range it covers.
struct ProcessHistoryView: View {
    let history: MetricsHistory?
    let range: MonitorView.Range
    @State private var usage: ProcessUsageHistory?
    @State private var errorMessage: String?
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Process history").font(.mh(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                if refreshing { ProgressView().controlSize(.small).help("Updating process history…") }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.mhCaption)
                    .foregroundStyle(Theme.rose)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let usage, !usage.byCPU.isEmpty || !usage.byMemory.isEmpty {
                Text("Only each minute’s top 10 processes by CPU and by memory are kept, so a process missing from a minute may still have been running. Averages cover only the minutes a process appears in.")
                    .font(.mhCaption)
                    .foregroundStyle(Palette.textMuted)
                HairlinePanel(columns: 2) {
                    column("Top processes by CPU", ranks: usage.byCPU,
                           totalMinutes: usage.totalMinuteCount, showsMemory: false)
                    column("Top processes by memory", ranks: usage.byMemory,
                           totalMinutes: usage.totalMinuteCount, showsMemory: true)
                }
            } else if errorMessage == nil, (usage?.hiddenCount ?? 0) == 0 {
                PixelEmptyState(art: "px.mascot",
                                title: "No process history yet",
                                message: "Process rankings appear after a minute of recording. Turn on Record process usage in Settings → General → Data management, then check back.") { EmptyView() }
                    .frame(minHeight: 260)
            }
            if let usage, usage.hiddenCount > 0 {
                Text("Up to \(usage.hiddenCount) processes per minute couldn’t be read and are not included.")
                    .font(.mhCaption)
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .task(id: range) {
            guard let history else { usage = nil; errorMessage = nil; return }
            while !Task.isCancelled {
                if let cached = ProcessHistoryCache.entries[range] {
                    usage = cached.usage
                    errorMessage = nil
                    PageLoadProbe.mark(.monitor, "processes")
                    if range != .live, Date().timeIntervalSince(cached.at) < ProcessHistoryCache.maxAge {
                        refreshing = false
                        return
                    }
                }
                let now = Date()
                let since = now.addingTimeInterval(-range.seconds)
                refreshing = true
                defer { refreshing = false }
                do {
                    let loaded = try await Task.detached { try history.processUsage(since: since, until: now) }.value
                    guard !Task.isCancelled else { return }
                    usage = loaded
                    errorMessage = nil
                    ProcessHistoryCache.entries[range] = (loaded, Date())
                    PageLoadProbe.mark(.monitor, "processes")
                    PageLoadProbe.mark(.monitor, "processes-refresh")
                } catch {
                    errorMessage = String(localized: "Couldn’t read process history: \(error.localizedDescription)")
                }
                // A minute is only written when it closes; refresh the live window while it
                // is shown, and load a fixed range once.
                guard range == .live else { return }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func column(_ title: LocalizedStringKey, ranks: [ProcessUsageRank],
                        totalMinutes: Int, showsMemory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.label).foregroundStyle(Palette.textMuted)
            if ranks.isEmpty {
                Text("No data in this range").font(.mh(size: 12)).foregroundStyle(Palette.textMuted)
            }
            ForEach(ranks, id: \.name) { rank in
                HStack(spacing: 8) {
                    Text(rank.name)
                        .font(.mh(size: 13))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("\(rank.minuteCount) of \(totalMinutes) min")
                        .font(.mh(size: 10.5))
                        .foregroundStyle(Palette.textFaint)
                    Text(showsMemory ? Fmt.memory(UInt64(max(rank.averageMemoryBytes, 0))) : Fmt.percent(rank.averageCPU))
                        .font(Theme.smallNumeral)
                        .foregroundStyle(Palette.text)
                        .frame(minWidth: 58, alignment: .trailing)
                }
                .frame(height: 26)
            }
        }
        .padding(16)
    }
}
