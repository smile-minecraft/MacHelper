import AppKit
import Metrics
import SwiftUI

/// Menu bar network page: connection, current rates with their 5-minute peak, the traffic trend
/// and which apps use the network.
struct PanelNetworkTab: View {
    let store: MonitorStore
    @State private var model = NetworkPanelModel()
    @State private var history = PanelHistory()
    @AppStorage("panel.network.range") private var range: PanelRange = .live

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConnectionCard(model: model)
            rateCards
            trendCard
            NetworkTrafficSources(snapshot: model.traffic)
            if let details = model.details {
                HairlineHeader(text: "Interfaces")
                NetworkDetailsContent(snapshot: details)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .task(id: range) { await history.run(range, history: store.persistentHistory) }
    }

    // MARK: Rates

    private var rateCards: some View {
        let down = PanelSeries.live(store, .netIn)
        let up = PanelSeries.live(store, .netOut)
        return HStack(spacing: 10) {
            RateCard(title: "Download", symbol: "arrow.down", color: Theme.blue,
                     value: store.network?.inBytesPerSecond, peak: store.history[.netIn]?.map(\.value).max(), spark: down.map(\.value))
            RateCard(title: "Upload", symbol: "arrow.up", color: Theme.rose,
                     value: store.network?.outBytesPerSecond, peak: store.history[.netOut]?.map(\.value).max(), spark: up.map(\.value))
        }
    }

    // MARK: Trend

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelCardHeader(title: "Traffic", subtitle: "All interfaces") {
                ChipBar(items: PanelRange.chips, selection: $range)
            }
            HStack(spacing: 10) {
                LegendDot(color: Theme.blue, title: String(localized: "Download"))
                LegendDot(color: Theme.rose, title: String(localized: "Upload"))
            }
            PanelTrendChart(series: trendSeries, range: range, format: { Fmt.rateLong($0) }, minimumMax: 64 * 1024)
        }
        .padding(12)
        .surface(Palette.base)
    }

    private var trendSeries: [TrendSeries] {
        let down: [ChartPoint], up: [ChartPoint]
        if range == .live {
            down = PanelSeries.live(store, .netIn)
            up = PanelSeries.live(store, .netOut)
        } else {
            down = PanelSeries.history(history.samples, \.networkIn)
            up = PanelSeries.history(history.samples, \.networkOut)
        }
        return [TrendSeries(id: "down", name: String(localized: "Download"), color: Theme.blue, points: down),
                TrendSeries(id: "up", name: String(localized: "Upload"), color: Theme.rose, points: up)]
    }
}

// MARK: - Connection

private struct ConnectionCard: View {
    let model: NetworkPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.mh(size: 20, weight: .semibold))
                    .foregroundStyle(model.isOffline ? Palette.textFaint : Theme.mint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(model.isOffline ? Theme.rose : Theme.mint).frame(width: 7, height: 7)
                        Text(verbatim: title).font(.mh(size: 14, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                    }
                    Text(verbatim: subtitle).font(.mh(size: 11)).foregroundStyle(Palette.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if !metrics.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(metrics.enumerated()), id: \.offset) { i, m in
                        if i > 0 { Rectangle().fill(Palette.hairline).frame(width: 1, height: 30) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.label).font(.mh(size: 10.5)).foregroundStyle(Palette.textFaint).lineLimit(1)
                            Text(verbatim: m.value).font(.display(13.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(m.color ?? Palette.text).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, i > 0 ? 10 : 0)
                    }
                }
            }
        }
        .padding(12)
        .surface(Palette.base)
        .accessibilityElement(children: .combine)
    }

    private var isWiFi: Bool {
        guard let wifi = model.wifi, wifi.isAssociated else { return false }
        if let primary = model.primary { return primary.name == wifi.interfaceName }
        return true
    }

    private var symbol: String {
        if model.isOffline { return "wifi.slash" }
        if isWiFi { return "wifi" }
        switch model.primary?.details?.kind {
        case .ethernet: return "cable.connector"
        case .tunnel: return "lock.shield"
        default: return "network"
        }
    }

    private var title: String {
        if model.isOffline { return String(localized: "Not connected") }
        if isWiFi { return String(localized: "Wi-Fi · Connected") }
        guard let primary = model.primary else {
            return model.details == nil ? String(localized: "Checking connection…") : String(localized: "Connected")
        }
        let name = primary.details?.displayName ?? primary.name
        return String(localized: "\(name) · Connected")
    }

    private var subtitle: String {
        if isWiFi, let wifi = model.wifi {
            return [wifi.ssid ?? wifi.interfaceName, wifi.standard?.title].compactMap { $0 }.joined(separator: " · ")
        }
        if let primary = model.primary { return primary.name }
        if model.isOffline { return String(localized: "No interface carries the default route") }
        return " "
    }

    private struct Metric {
        let label: LocalizedStringKey
        let value: String
        var color: Color?
    }

    private var metrics: [Metric] {
        var out: [Metric] = []
        if isWiFi, let wifi = model.wifi {
            if let rssi = wifi.rssi {
                out.append(Metric(label: "Signal", value: "\(rssi) dBm (\(qualityText(wifi.quality)))", color: qualityColor(wifi.quality)))
            }
            if let rate = wifi.transmitRateMbps {
                out.append(Metric(label: "Link rate", value: Self.mbps(rate)))
            }
        } else if let details = model.primary?.details, case .available(let bps) = details.linkSpeedBitsPerSecond {
            out.append(Metric(label: "Link rate", value: Self.mbps(Double(bps) / 1_000_000)))
        }
        if let ip = model.primary?.details?.ipv4.first?.address {
            out.append(Metric(label: "IP address", value: ip))
        }
        return out
    }

    static func mbps(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.1f Gbps", v / 1000) : String(format: "%.0f Mbps", v)
    }

    private func qualityText(_ q: WiFiReading.Quality?) -> String {
        switch q {
        case .excellent: String(localized: "Excellent")
        case .good: String(localized: "Good")
        case .fair: String(localized: "Fair")
        case .weak: String(localized: "Weak")
        case nil: "–"
        }
    }

    private func qualityColor(_ q: WiFiReading.Quality?) -> Color? {
        switch q {
        case .fair: Theme.amber
        case .weak: Theme.rose
        default: nil
        }
    }
}

// MARK: - Rate card

private struct RateCard: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color
    let value: Double?
    let peak: Double?
    let spark: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.mh(size: 11, weight: .bold)).foregroundStyle(color)
                Text(title).font(.mh(size: 12, weight: .medium)).foregroundStyle(Palette.textMuted)
            }
            Text(verbatim: Fmt.rateLong(value))
                .font(.display(24, weight: .bold).monospacedDigit())
                .foregroundStyle(Palette.text)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text("Peak \(Fmt.rateLong(peak))")
                .font(.mh(size: 10.5).monospacedDigit())
                .foregroundStyle(Palette.textFaint)
            AreaSparkline(values: spark, maxValue: nil, color: color)
                .equatable()
                .frame(height: 28)
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Palette.base)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Traffic sources

/// Busiest apps by network use, from `nettop` snapshots. A helper process counts toward its app.
struct NetworkTrafficSources: View {
    let snapshot: ProcessNetworkSnapshot?
    @AppStorage("panel.network.sort") private var sort: Sort = .rate

    enum Sort: String, CaseIterable { case rate, download, upload, total }

    private static let visibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelCardHeader(title: "Traffic by app") {
                ChipBar(items: [(Sort.rate, "Now"), (.download, "Down"), (.upload, "Up"), (.total, "Total")], selection: $sort)
            }
            if let snapshot {
                let sorted = sortedItems(snapshot)
                if sorted.isEmpty {
                    Text("No app sent or received data in the last few seconds.")
                        .font(.mh(size: 11)).foregroundStyle(Palette.textMuted)
                } else {
                    columnHeader
                }
                let shown = Array(sorted.prefix(Self.visibleRows))
                let rest = Array(sorted.dropFirst(Self.visibleRows))
                let total = sorted.reduce(0) { $0 + metric($1) }
                ForEach(shown) { item in
                    row(icon: ProcessIcon.icon(appPath: item.appPath), name: item.name,
                        detail: item.processCount > 1 ? String(localized: "\(item.processCount) processes") : nil,
                        down: down(item), up: up(item), share: total > 0 ? metric(item) / total : 0, help: item.path ?? item.name)
                        .contextMenu { menu(item) }
                }
                if !rest.isEmpty {
                    row(icon: nil, name: String(localized: "Other apps (\(rest.count))"), detail: nil,
                        down: rest.reduce(0) { $0 + (down($1) ?? 0) }, up: rest.reduce(0) { $0 + (up($1) ?? 0) },
                        share: total > 0 ? rest.reduce(0) { $0 + metric($1) } / total : 0, help: nil)
                }
            } else {
                SkeletonRows(count: 4).padding(.vertical, 4)
            }
        }
        .padding(12)
        .surface(Palette.base)
    }

    private var columnHeader: some View {
        HStack(spacing: 6) {
            Text("App").frame(maxWidth: .infinity, alignment: .leading)
            Text(sort == .total ? "Received" : "Down").frame(width: 66, alignment: .trailing)
            Text(sort == .total ? "Sent" : "Up").frame(width: 66, alignment: .trailing)
            Text("Share").frame(width: 78, alignment: .trailing)
        }
        .font(.mh(size: 10.5, weight: .medium))
        .foregroundStyle(Palette.textFaint)
    }

    private func row(icon: NSImage?, name: String, detail: String?, down: Double?, up: Double?, share: Double, help: String?) -> some View {
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
            Text(verbatim: value(down)).frame(width: 66, alignment: .trailing)
                .foregroundStyle(sort == .download ? Theme.blue : Palette.text)
            Text(verbatim: value(up)).frame(width: 66, alignment: .trailing)
                .foregroundStyle(sort == .upload ? Theme.rose : Palette.text)
            HStack(spacing: 5) {
                Meter(fraction: share, color: sort == .upload ? Theme.rose : Theme.blue)
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

    @ViewBuilder private func menu(_ item: ProcessNetworkUsage) -> some View {
        if let path = item.appPath ?? item.path {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
    }

    private func value(_ v: Double?) -> String {
        sort == .total ? v.map { Fmt.byteAmount($0) } ?? "–" : Fmt.rateLong(v)
    }

    private func down(_ i: ProcessNetworkUsage) -> Double? { sort == .total ? Double(i.totalInBytes) : i.inBytesPerSecond }
    private func up(_ i: ProcessNetworkUsage) -> Double? { sort == .total ? Double(i.totalOutBytes) : i.outBytesPerSecond }

    private func metric(_ i: ProcessNetworkUsage) -> Double {
        switch sort {
        case .rate: i.totalBytesPerSecond ?? Double(i.totalBytes)
        case .download: i.inBytesPerSecond ?? Double(i.totalInBytes)
        case .upload: i.outBytesPerSecond ?? Double(i.totalOutBytes)
        case .total: Double(i.totalBytes)
        }
    }

    private func sortedItems(_ s: ProcessNetworkSnapshot) -> [ProcessNetworkUsage] {
        // Before the first rates exist, every mode falls back to the totals.
        s.items.filter { metric($0) > 0 }
            .sorted { metric($0) != metric($1) ? metric($0) > metric($1) : $0.id < $1.id }
    }
}
