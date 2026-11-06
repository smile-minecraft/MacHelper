import CleanEngine
import SwiftUI

struct OperationHistoryView: View {
    @State private var model = OperationHistoryModel()

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            summary
            if model.entries.isEmpty {
                message("No operations logged yet.")
            } else if model.filtered.isEmpty {
                message("No records match these filters.")
            } else {
                switch model.display {
                case .records: list
                case .bySource: sourceList
                case .byMonth: monthList
                }
            }
            footer
        }
        .background(Palette.base)
        .task { model.load() }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            ChipBar(items: OperationHistoryModel.Period.allCases.map { ($0, $0.title) },
                    selection: $model.period)
            Picker("Type", selection: $model.kind) {
                Text("All types").tag(OperationKind?.none)
                ForEach(OperationKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(Optional(kind))
                }
            }
            .labelsHidden()
            .frame(minWidth: 150)
            Picker("Show", selection: $model.display) {
                Text("Records").tag(OperationHistoryModel.Display.records)
                Text("By rule").tag(OperationHistoryModel.Display.bySource)
                Text("By month").tag(OperationHistoryModel.Display.byMonth)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Refresh") { model.load() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 7) {
            HairlinePanel(columns: 4) {
                summaryCell("Moved to Trash", value: bytes(model.summary.trashedBytes))
                summaryCell("Deleted permanently", value: bytes(model.summary.deletedBytes))
                summaryCell("Succeeded", value: "\(model.summary.succeededCount)")
                summaryCell("Failed", value: "\(model.summary.failedCount)",
                            color: model.summary.failedCount > 0 ? Theme.rose : nil)
            }
            Text("Sizes are recorded in the operation log; they don't measure how much disk space changed. Items moved to the Trash still use space until the Trash is emptied.")
                .settingsCaption()
            Text("This page only reads the log. It never removes anything.")
                .settingsCaption(Palette.textFaint)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var list: some View {
        List(Array(model.filtered.enumerated()), id: \.offset) { _, entry in
            row(entry)
                .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ entry: OperationLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.time.formatted(date: .abbreviated, time: .shortened))
                        .font(.mhCaption.monospacedDigit())
                        .foregroundStyle(Palette.textMuted)
                    Badge(text: entry.kind.title, color: entry.kind.color)
                    Badge(text: entry.status.title, color: entry.status.color)
                }
                Text(entry.path.isEmpty ? entry.source : entry.path)
                    .font(.mhCallout)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.path.isEmpty ? entry.source : entry.path)
                if let message = entry.message, !message.isEmpty {
                    Text(message).settingsCaption()
                }
            }
            Spacer(minLength: 8)
            if entry.bytes > 0 {
                Text(bytes(entry.bytes))
                    .font(.mhCaption.monospacedDigit())
                    .foregroundStyle(Palette.textMuted)
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.skippedLines > 0 {
                Label("\(model.skippedLines) lines couldn't be read and were skipped.", systemImage: "exclamationmark.triangle")
                    .settingsCaption(Theme.amber)
            }
            Spacer()
            Text("Showing \(model.filtered.count) of \(model.entries.count) records")
                .settingsCaption(Palette.textFaint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Palette.card)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.mh(size: 30))
                .foregroundStyle(Palette.textFaint)
                .accessibilityHidden(true)
            Text(text).foregroundStyle(Palette.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceList: some View {
        List {
            Section {
                ForEach(model.sourceStats) { s in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.title(for: s.source)).foregroundStyle(Palette.text)
                            Text(s.source).font(.mhCaption2.monospaced()).foregroundStyle(Palette.textFaint)
                        }
                        Spacer()
                        Text(bytes(s.bytes)).font(.mhCallout.monospacedDigit()).foregroundStyle(Palette.text)
                        Text("\(s.items) items on \(s.days) days").font(.mhCaption).foregroundStyle(Palette.textMuted)
                            .frame(width: 140, alignment: .trailing)
                        Text(s.last, format: .dateTime.year().month().day()).font(.mhCaption).foregroundStyle(Palette.textMuted)
                            .frame(width: 90, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("What each rule, detector or task removed in the records shown, largest first. Rules that never appear here may not be worth selecting.")
                    .font(.mhCaption).foregroundStyle(Palette.textMuted).textCase(nil)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var monthList: some View {
        let totals = model.monthTotals
        let peak = max(totals.map { $0.trashedBytes + $0.deletedBytes }.max() ?? 1, 1)
        return List(totals) { m in
            HStack(spacing: 12) {
                Text(m.month, format: .dateTime.year().month(.wide)).frame(width: 130, alignment: .leading).foregroundStyle(Palette.text)
                GeometryReader { geo in
                    SurfaceShape(cornerRadius: 3).fill(Theme.amber.opacity(0.7))
                        .frame(width: max(2, geo.size.width * Double(m.trashedBytes + m.deletedBytes) / Double(peak)))
                }
                .frame(height: 10)
                .accessibilityHidden(true)
                Text("Trash \(bytes(m.trashedBytes)) · deleted \(bytes(m.deletedBytes))")
                    .font(.mhCaption.monospacedDigit()).foregroundStyle(Palette.textMuted).frame(width: 220, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
        }
        .scrollContentBackground(.hidden)
    }

    private func summaryCell(_ title: LocalizedStringKey, value: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.label).foregroundStyle(Palette.textMuted)
            Text(value).font(Theme.mediumNumeral).foregroundStyle(color ?? Palette.text).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func bytes(_ value: UInt64) -> String {
        Fmt.bytes(Int64(clamping: value))
    }
}

private struct Badge: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(.mhCaption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: SurfaceShape.capsule)
            .foregroundStyle(color)
    }
}

private extension OperationHistoryModel.Period {
    var title: LocalizedStringKey {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All time"
        }
    }
}

private extension OperationKind {
    var title: LocalizedStringKey {
        switch self {
        case .cleanup: "Cleaning"
        case .uninstall: "Uninstall"
        case .appUpdate: "App Updates"
        case .startup: "Startup Items"
        case .maintenance: "Maintenance"
        case .diskAnalysis: "Disk Analysis"
        case .other: "Other"
        }
    }

    var color: Color {
        switch self {
        case .cleanup: Theme.mint
        case .uninstall: Theme.rose
        case .appUpdate: Theme.mint
        case .startup: Theme.orange
        case .maintenance: Theme.amber
        case .diskAnalysis: Theme.violet
        case .other: Theme.slate
        }
    }
}

private extension OperationStatus {
    var title: LocalizedStringKey {
        switch self {
        case .succeeded: "Succeeded"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }

    var color: Color {
        switch self {
        case .succeeded: Theme.mint
        case .skipped: Palette.textMuted
        case .failed: Theme.rose
        }
    }
}
