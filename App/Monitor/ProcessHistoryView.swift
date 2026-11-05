import Storage
import SwiftUI

/// Process rankings for the selected range, read from the shared minute history. Only each
/// minute's top ten by CPU and by memory are stored, so the caption explains that a missing
/// process may still have been running and each row shows how much of the range it covers.
struct ProcessHistoryView: View {
    let history: MetricsHistory?
    let range: MonitorView.Range
    @State private var usage: ProcessUsageHistory?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Process history").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.rose)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let usage, !usage.byCPU.isEmpty || !usage.byMemory.isEmpty {
                Text("Only each minute’s top 10 processes by CPU and by memory are kept, so a process missing from a minute may still have been running. Averages cover only the minutes a process appears in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: range) {
            guard let history else { usage = nil; errorMessage = nil; return }
            while !Task.isCancelled {
                let now = Date()
                let since = now.addingTimeInterval(-range.seconds)
                do {
                    usage = try await Task.detached { try history.processUsage(since: since, until: now) }.value
                    errorMessage = nil
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
                Text("No data in this range").font(.system(size: 12)).foregroundStyle(Palette.textMuted)
            }
            ForEach(ranks, id: \.name) { rank in
                HStack(spacing: 8) {
                    Text(rank.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("\(rank.minuteCount) of \(totalMinutes) min")
                        .font(.system(size: 10.5))
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
