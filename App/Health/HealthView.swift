import Charts
import Diagnostics
import Storage
import SwiftUI

struct HealthView: View {
    let app: AppModel
    @Bindable var model: HealthModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(section: .health, subtitle: String(localized: "A one-off check of the last hours of history, free space and background items.")) {
                    Picker("Period", selection: $model.window) {
                        Text("1 hour").tag(HealthModel.Window.hour)
                        Text("24 hours").tag(HealthModel.Window.day)
                        Text("7 days").tag(HealthModel.Window.week)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    IconButton(symbol: "arrow.clockwise", help: "Run again") { Task { await reload() } }
                        .disabled(model.loading)
                }
                if let error = model.error {
                    Text(error).font(.mhCallout).foregroundStyle(Theme.amber).textSelection(.enabled)
                }
                if let report = model.report {
                    findings(report)
                    summary(report)
                    DiskTrendCard(points: model.diskPoints, forecast: report.diskForecast, free: report.system.diskFreeBytes)
                    SecuritySection(model: model)
                    processes(report)
                } else if model.loading {
                    VStack(spacing: 12) {
                        ScanningArt(art: "px.empty.scan")
                        Text("Checking…").font(.mhCallout).foregroundStyle(Palette.textMuted)
                        ProgressView().controlSize(.small)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .task(id: model.window) { await reload() }
        .task { await model.loadSecurity() }
    }

    private func reload() async { await model.load(history: app.store.persistentHistory) }

    // MARK: Findings

    private func findings(_ report: HealthReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if report.findings.isEmpty {
                Label("No problems found in this period.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.mint).font(.mhHeadline)
                    .card()
            }
            ForEach(report.findings) { f in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(f.severity)).foregroundStyle(color(f.severity)).font(.mhTitle3)
                        .accessibilityLabel(severityLabel(f.severity))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.title).font(.mhHeadline).foregroundStyle(Palette.text)
                        Text(f.detail).font(.mhCallout).foregroundStyle(Palette.textMuted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if let section = action(f.id) {
                        Button(section.title) { app.section = section }
                    }
                }
                .card()
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func action(_ id: String) -> AppSection? {
        switch id {
        case "disk.low", "disk.trend": .optimize
        case "background.many": .startup
        case "cpu.busy", "cpu.process", "memory.high", "thermal.hot": .monitor
        default: nil
        }
    }

    private func symbol(_ s: HealthReport.Severity) -> String {
        switch s {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .ok: "checkmark.circle.fill"
        }
    }

    private func color(_ s: HealthReport.Severity) -> Color {
        switch s {
        case .critical: Theme.rose
        case .warning: Theme.amber
        case .info: Theme.blue
        case .ok: Theme.mint
        }
    }

    private func severityLabel(_ s: HealthReport.Severity) -> String {
        switch s {
        case .critical: String(localized: "Critical")
        case .warning: String(localized: "Warning")
        case .info: String(localized: "Note")
        case .ok: String(localized: "OK")
        }
    }

    // MARK: Summary

    private func summary(_ report: HealthReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Four equal columns across the card instead of a block packed to the left.
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    stat("CPU", "\(Fmt.percent(report.cpu.average)) · \(Fmt.percent(report.cpu.maximum))")
                    stat("Memory", "\(Fmt.percent(report.memory.average)) · \(Fmt.percent(report.memory.maximum))")
                    stat("Temperature", Fmt.celsius(report.temperature.maximum))
                    stat("Power", Fmt.watts(report.power.average))
                }
                GridRow {
                    stat("Recorded", Fmt.percent(report.coverage))
                    stat("Swap", report.system.swapUsedBytes.map { Fmt.bytes(Int64($0)) } ?? "–")
                    stat("Uptime", report.system.uptimeSeconds.map { Duration.seconds($0).formatted(.units(allowed: [.days, .hours], width: .abbreviated)) } ?? "–")
                    stat("Background items", report.system.activeBackgroundItems.map { "\($0)" } ?? "–",
                         note: report.system.activeBackgroundItems == nil ? String(localized: "Needs the Helper") : nil)
                }
            }
            Text("CPU and memory: average · highest. Temperature: highest. Power: average.")
                .font(.mhCaption2).foregroundStyle(Palette.textFaint)
        }
        .card()
    }

    private func stat(_ title: LocalizedStringKey, _ value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.mhCaption).foregroundStyle(Palette.textMuted)
            Text(value).font(Theme.smallNumeral).foregroundStyle(Palette.text)
            if let note { Text(note).font(.mhCaption2).foregroundStyle(Theme.amber) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Processes

    @ViewBuilder
    private func processes(_ report: HealthReport) -> some View {
        if report.topByCPU.isEmpty && report.topByMemory.isEmpty {
            Text("Turn on “Record process usage” in Settings → General → Data to see which processes were busiest.")
                .font(.mhCallout).foregroundStyle(Palette.textMuted).card()
        } else {
            HStack(alignment: .top, spacing: 16) {
                processList("Busiest by CPU", report.topByCPU) { Fmt.percent($0.averageCPU) }
                processList("Largest by memory", report.topByMemory) { Fmt.memory(UInt64(max($0.averageMemoryBytes, 0))) }
            }
        }
    }

    private func processList(_ title: LocalizedStringKey, _ lines: [HealthReport.ProcessLine],
                             value: @escaping (HealthReport.ProcessLine) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.mhHeadline)
            ForEach(lines, id: \.name) { line in
                HStack {
                    Text(line.name).lineLimit(1).foregroundStyle(Palette.text)
                    Spacer()
                    Text(value(line)).font(.mhCallout.monospacedDigit()).foregroundStyle(Palette.text)
                    Text("\(Fmt.percent(line.presence)) of the time").font(.mhCaption).foregroundStyle(Palette.textMuted)
                        .frame(width: 110, alignment: .trailing)
                }
            }
            Text("CPU is the share of one core while the process was among the busiest.")
                .font(.mhCaption2).foregroundStyle(Palette.textFaint)
        }
        .card()
    }
}

/// Hourly free space for the last 30 days, with the trend's projection when space is shrinking.
private struct DiskTrendCard: View {
    let points: [DiskSpacePoint]
    let forecast: DiskSpaceForecast?
    let free: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Free space on the startup disk").font(.mhHeadline)
                Spacer()
                if let free { Text(Fmt.bytes(Int64(free))).font(Theme.smallNumeral) }
            }
            Text(caption).font(.mhCallout).foregroundStyle(Palette.textMuted)
            if points.count >= 2 {
                Chart {
                    ForEach(points, id: \.time) { p in
                        LineMark(x: .value("Time", p.time), y: .value("Free", p.free / 1e9))
                            .foregroundStyle(Theme.violet)
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYAxisLabel("GB")
                .frame(height: 140)
                .accessibilityLabel(Text("Free space chart"))
            }
        }
        .card()
    }

    private var caption: String {
        guard let forecast else {
            return points.count < 2
                ? String(localized: "MacHelper records free space once an hour while it or background recording runs. The trend appears after about 12 hours.")
                : String(localized: "Not enough data since the last big change for a trend yet (needs about 12 hours).")
        }
        let perDay = Fmt.bytes(Int64(abs(forecast.bytesPerDay)))
        if let days = forecast.daysUntilFull {
            return String(localized: "Shrinking by about \(perDay) a day; full in about \(Int(days.rounded())) days at this rate.")
        }
        return forecast.bytesPerDay < 0
            ? String(localized: "Stable: changing by less than 50 MB a day.")
            : String(localized: "Growing by about \(perDay) a day.")
    }
}
