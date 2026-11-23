import FanControl
import Metrics
import SMCKit
import SwiftUI

/// The fan half of the power page: fan speed, the temperatures that drive it, speed against
/// chip temperature over time, and a one-click fan mode.
struct PanelFanSection: View {
    let store: MonitorStore
    var openFanControl: () -> Void
    @State private var history = PanelHistory()
    @AppStorage("panel.fan.range") private var range: PanelRange = .live

    private var fanModel: FanControlModel { AppModel.shared.fanModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HairlineHeader(text: "Fans")
            if !store.isActive(.fan) {
                PanelEmptyState(symbol: "fan.slash", title: "Fan readings are off",
                                detail: "Turn on Fans in the menu bar settings to see fan speed here.")
            } else if store.fans.isEmpty {
                SkeletonRows(count: 5).padding(.top, 8)
            } else {
                // Both columns take the taller one's height, so the card edges line up.
                HStack(alignment: .top, spacing: 8) {
                    HottestCard(reading: store.temperatures.max { $0.celsius < $1.celsius })
                        .frame(width: 148)
                        .frame(maxHeight: .infinity)
                    VStack(spacing: 8) {
                        ForEach(store.fans) {
                            FanSpeedCard(fan: $0, count: store.fans.count).frame(maxHeight: .infinity)
                        }
                        temperatureRow
                    }
                    .frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                trendCard
                // Fan control belongs to the Fans module; the speeds above stay as readings.
                if FeatureStore.shared.isEnabled(.fans) {
                    FanModeBar(model: fanModel, fans: store.fans, openFanControl: openFanControl)
                }
            }
        }
        .task(id: range) { await history.run(range, history: store.persistentHistory) }
        .task(id: FeatureStore.shared.isEnabled(.fans)) {
            guard FeatureStore.shared.isEnabled(.fans) else { return }
            // The fan window polls on its own; here one status read every few seconds is enough
            // to keep the selected mode current.
            while !Task.isCancelled {
                await fanModel.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Temperatures

    private var temperatureRow: some View {
        let t = store.temperatures
        let tiles: [(LocalizedStringKey, String, Double?)] = [
            ("CPU", "cpu", store.cpuCelsius),
            ("GPU", "square.stack.3d.up", t.filter { $0.category == .gpu }.map(\.celsius).max()),
            ("SSD", "internaldrive", t.filter { $0.category == .storage }.map(\.celsius).max()),
        ]
        return HStack(spacing: 8) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                TemperatureTile(title: tile.0, symbol: tile.1, celsius: tile.2)
            }
        }
    }

    // MARK: Trend

    private var maxRPM: Double { store.fans.map(\.maxRPM).max().map { max($0, 1000) } ?? 6000 }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelCardHeader(title: "Speed and temperature") {
                ChipBar(items: PanelRange.chips, selection: $range)
            }
            HStack(spacing: 10) {
                Text("rpm").font(.mh(size: 9.5)).foregroundStyle(Palette.textFaint)
                LegendDot(color: Theme.violet, title: String(localized: "Fan speed"))
                LegendDot(color: Theme.cyan, title: String(localized: "CPU temperature"))
                Spacer()
                Text("°C").font(.mh(size: 9.5)).foregroundStyle(Palette.textFaint)
            }
            PanelTrendChart(series: trendSeries, range: range, format: { Fmt.rpm($0) },
                            secondary: SecondaryAxis(domain: 30...110, format: { "\(Int($0.rounded()))°" }),
                            primaryDomain: 0...maxRPM, height: 160)
        }
        .padding(12)
        .surface(Palette.base)
    }

    private var trendSeries: [TrendSeries] {
        let fan: [ChartPoint], temp: [ChartPoint]
        if range == .live {
            fan = PanelSeries.live(store, .fan)
            temp = PanelSeries.live(store, .temperature)
        } else {
            fan = PanelSeries.history(history.samples, \.fan)
            temp = PanelSeries.history(history.samples, \.temperature)
        }
        return [
            TrendSeries(id: "fan", name: String(localized: "Fan speed"), color: Theme.violet, points: fan),
            TrendSeries(id: "temp", name: String(localized: "CPU temperature"), color: Theme.cyan, points: temp,
                        secondary: true, filled: false),
        ]
    }
}

private struct FanSpeedCard: View {
    let fan: FanReading
    let count: Int

    private var fraction: Double {
        guard fan.maxRPM > fan.minRPM else { return 0 }
        return (fan.actualRPM - fan.minRPM) / (fan.maxRPM - fan.minRPM)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "fan.fill").font(.mh(size: 11, weight: .semibold)).foregroundStyle(Theme.violet)
                Text(count > 1 ? "Fan \(fan.id + 1)" : "Fan speed").font(.mh(size: 11, weight: .medium)).foregroundStyle(Palette.textMuted)
                Spacer(minLength: 0)
                Text(fan.mode == .automatic ? "Auto" : "Manual")
                    .font(.mh(size: 9.5, weight: .semibold))
                    .foregroundStyle(fan.mode == .automatic ? Palette.textMuted : Theme.violet)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.inset, in: SurfaceShape(capsule: true))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: Fmt.rpm(fan.actualRPM)).font(.display(count > 1 ? 18 : 24, weight: .bold).monospacedDigit())
                    .foregroundStyle(Palette.text)
                Text("rpm").font(.mh(size: 11)).foregroundStyle(Palette.textMuted)
            }
            Meter(fraction: fraction, color: Theme.violet)
            Text("\(Fmt.rpm(fan.minRPM))–\(Fmt.rpm(fan.maxRPM)) rpm")
                .font(.mh(size: 10).monospacedDigit()).foregroundStyle(Palette.textFaint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .surface(Palette.base, wash: Theme.violet.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

/// The hottest sensor as the page's main number, beside a thermometer filled to it.
private struct HottestCard: View {
    let reading: TemperatureReading?

    private var celsius: Double? { reading?.celsius }
    private var status: Reading? { StatusRules.temperature(celsius) }
    private var color: Color {
        guard let status else { return Palette.textFaint }
        return status.level == .good ? ((celsius ?? 0) >= 65 ? Theme.amber : Theme.cyan) : status.level.color
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Thermometer(fraction: celsius.map { ($0 - 30) / 80 } ?? 0, color: color)
                .frame(width: 26)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Hottest sensor").font(.mh(size: 11, weight: .medium)).foregroundStyle(Palette.textMuted).lineLimit(1)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(verbatim: celsius.map { String(format: "%.1f", $0) } ?? "–")
                        .font(.display(26, weight: .bold).monospacedDigit())
                        .foregroundStyle(Palette.text)
                    Text(verbatim: "°C").font(.mh(size: 12, weight: .semibold)).foregroundStyle(Palette.textMuted)
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                if let status {
                    Text(verbatim: status.word).font(.mh(size: 11, weight: .semibold)).foregroundStyle(color)
                }
                Spacer(minLength: 0)
                if let reading {
                    Text(verbatim: Fmt.sensorName(reading.name))
                        .font(.mh(size: 9.5)).foregroundStyle(Palette.textFaint).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .surface(Palette.base)
        .accessibilityElement(children: .combine)
    }
}

/// A tube with a bulb, filled from the bulb up; ticks mark 30, 50, 70, 90 and 110 °C.
private struct Thermometer: View {
    @Environment(\.animatesReadings) private var animatesReadings
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let bulb = geo.size.width
            let tube = bulb * 0.46
            let tubeTop: CGFloat = tube / 2
            let tubeBottom = geo.size.height - bulb * 0.8
            let level = min(max(fraction, 0), 1)
            let fillTop = tubeBottom - (tubeBottom - tubeTop) * level
            ZStack(alignment: .topLeading) {
                // Ticks on the tube's left.
                ForEach(0..<5) { i in
                    let y = tubeBottom - (tubeBottom - tubeTop) * CGFloat(i) / 4
                    Rectangle().fill(Palette.textFaint.opacity(0.6))
                        .frame(width: i % 2 == 0 ? 5 : 3, height: 1)
                        .position(x: (bulb - tube) / 2 - (i % 2 == 0 ? 4.5 : 3.5), y: y)
                }
                Capsule().fill(Palette.inset)
                    .frame(width: tube, height: tubeBottom - tubeTop + tube)
                    .position(x: bulb / 2, y: (tubeTop + tubeBottom) / 2)
                Circle().fill(Palette.inset)
                    .frame(width: bulb, height: bulb)
                    .position(x: bulb / 2, y: geo.size.height - bulb / 2)
                // Mercury: column plus bulb in one color.
                Capsule().fill(color.gradient)
                    .frame(width: tube * 0.56, height: max(tubeBottom - fillTop + tube * 0.56, tube * 0.56))
                    .position(x: bulb / 2, y: (fillTop + tubeBottom) / 2)
                    .animation(animatesReadings ? Motion.meter(0.5) : nil, value: fraction)
                Circle().fill(color.gradient)
                    .frame(width: bulb * 0.72, height: bulb * 0.72)
                    .position(x: bulb / 2, y: geo.size.height - bulb / 2)
                    .shadow(color: color.opacity(0.45), radius: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct TemperatureTile: View {
    let title: LocalizedStringKey
    let symbol: String
    let celsius: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.mh(size: 10, weight: .semibold)).foregroundStyle(Palette.textMuted)
                Text(title).font(.mh(size: 10.5, weight: .medium)).foregroundStyle(Palette.textMuted).lineLimit(1)
            }
            Text(verbatim: Fmt.celsiusLong(celsius))
                .font(.display(14, weight: .bold).monospacedDigit())
                .foregroundStyle(StatusRules.temperature(celsius)?.level.color ?? (celsius == nil ? Palette.textFaint : Palette.text))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Palette.base)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Fan mode

/// Automatic or one of the preset curves, applied through the Helper. Anything else (a fixed
/// speed or an edited curve) is "Custom" and opens the fan window.
private struct FanModeBar: View {
    let model: FanControlModel
    /// The SMC's own view of the fans, used until the Helper status arrives (or without it).
    let fans: [FanReading]
    let openFanControl: () -> Void

    enum Choice: Hashable { case automatic, quiet, balanced, performance, custom }

    private var current: Choice? {
        guard let policy = model.status?.policy else {
            // No Helper status: firmware control means Auto; anything else was set elsewhere.
            guard let first = fans.first else { return nil }
            return fans.allSatisfy { $0.mode == .automatic } && first.mode == .automatic ? .automatic : .custom
        }
        switch policy.mode {
        case .automatic: return .automatic
        case .fixed: return .custom
        case .curve(let s):
            switch FanProfile.matching(s.curve) {
            case .quiet: return .quiet
            case .balanced: return .balanced
            case .performance: return .performance
            case .custom: return .custom
            }
        }
    }

    private var helperReady: Bool { model.helperStatus == .enabled && model.status?.canControl != false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelCardHeader(title: "Fan mode") {
                if model.isApplying { ProgressView().controlSize(.mini) }
            }
            HStack(spacing: 4) {
                option(.automatic, "Auto")
                option(.quiet, "Quiet")
                option(.balanced, "Balanced")
                option(.performance, "Performance")
                option(.custom, "Custom…")
            }
            if !helperReady {
                Text("Changing the fan mode needs the Helper. Choose Custom… to set it up in Fan Control.")
                    .font(.mh(size: 10.5)).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.status?.safetyTripped == true {
                Text("Temperature safety limit reached: the system controls the fans until it cools down.")
                    .font(.mh(size: 10.5)).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .surface(Palette.base)
    }

    private func option(_ choice: Choice, _ title: LocalizedStringKey) -> some View {
        let selected = current == choice
        return Button {
            Task { await select(choice) }
        } label: {
            HStack(spacing: 3) {
                if selected { Image(systemName: "checkmark").font(.mh(size: 8.5, weight: .bold)) }
                Text(title).font(.mh(size: 11, weight: selected ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Palette.text : Palette.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(selected ? Theme.violet.opacity(0.22) : Palette.inset, in: SurfaceShape(cornerRadius: 7, style: .continuous))
            .overlay(SurfaceShape(cornerRadius: 7, style: .continuous).strokeBorder(selected ? Theme.violet.opacity(0.7) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Custom opens the fan window even without the Helper: that is where it gets set up.
        .disabled(choice != .custom && (!helperReady || model.isApplying))
    }

    private func select(_ choice: Choice) async {
        switch choice {
        case .automatic:
            await model.restoreAutomatic()
        case .quiet, .balanced, .performance:
            model.selectProfile(choice == .quiet ? .quiet : choice == .balanced ? .balanced : .performance)
            model.mode = .curve
            await model.apply()
        case .custom:
            openFanControl()
        }
    }
}
