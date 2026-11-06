import Charts
import FanControl
import HelperProtocol
import SwiftUI

struct FanControlView: View {
    @Bindable var model: FanControlModel
    var switcher: FanAutoSwitcher?
    let openHelperDiagnostics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.helperStatus != .enabled {
                helperMissing
            } else if let status = model.status, !status.canControl {
                Label("Fans on this Mac can’t be controlled (\(status.strategy))", systemImage: "fan.slash")
            } else {
                liveStatus.card()
                VStack(alignment: .leading, spacing: 14) {
                    editor
                    Divider()
                    footer
                }
                .card()
                if let switcher {
                    FanAutoSwitchSection(switcher: switcher).card()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    // MARK: Sections

    private var helperMissing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Fan control needs the Helper (\(model.helperStatus.label))", systemImage: "lock.shield")
            Button("Open Helper Diagnostics", action: openHelperDiagnostics)
        }
    }

    @ViewBuilder private var liveStatus: some View {
        if let s = model.status {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(s.fans) { f in
                    HStack {
                        Image(systemName: "fan")
                        Text("Fan \(f.id)").bold()
                        Text("\(Int(f.reading.actualRPM)) rpm").monospacedDigit()
                        Spacer()
                        if let c = f.commandedRPM {
                            Text("Helper target \(Int(c)) rpm").foregroundStyle(Theme.orange).monospacedDigit()
                        } else {
                            Text("System control (target \(Int(f.reading.targetRPM)))").foregroundStyle(Palette.textMuted).monospacedDigit()
                        }
                    }
                }
                HStack(spacing: 16) {
                    if let t = s.controlCelsius { Text("Curve temperature \(Fmt.celsius(t))") }
                    if let h = s.hottestCelsius { Text("Hottest \(Fmt.celsius(h))") }
                }
                .font(.mhCaption).foregroundStyle(Palette.textMuted)
                if s.safetyTripped {
                    Label("Temperature exceeded the safety limit; control was handed back to the system", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.rose).font(.mhCaption)
                }
                if let e = s.lastError {
                    Label(e, systemImage: "exclamationmark.circle").foregroundStyle(Theme.orange).font(.mhCaption)
                }
                if commandIgnored(s) {
                    Label("The firmware doesn’t seem to apply the Helper’s speed. On some models manual control only takes effect after the system has started the fans.",
                          systemImage: "info.circle")
                        .font(.mhCaption).foregroundStyle(Palette.textMuted)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $model.mode) {
                ForEach(FanControlModel.UIMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch model.mode {
            case .automatic:
                Text("The macOS firmware controls the fans based on temperature. This is the safest setting.")
                    .font(.mhCallout).foregroundStyle(Palette.textMuted)
            case .fixed:
                VStack(alignment: .leading) {
                    HStack {
                        Text("Speed")
                        Slider(value: $model.fixedFraction, in: 0...1)
                        Text(model.rpm(forFraction: model.fixedFraction).map { "\(Int($0)) rpm" } ?? Fmt.percent(model.fixedFraction))
                            .monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                    Text("A fixed speed needs the app to keep running; \(Int(HelperTiming.heartbeatTimeout)) seconds after the app quits, control returns to the system.")
                        .font(.mhCaption).foregroundStyle(Palette.textMuted)
                }
            case .curve:
                curveEditor
            }
        }
    }

    private var curveEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Profile", selection: Binding(get: { model.profile }, set: { model.selectProfile($0) })) {
                    Text("Quiet").tag(FanProfile.quiet)
                    Text("Balanced").tag(FanProfile.balanced)
                    Text("Performance").tag(FanProfile.performance)
                    Text("Custom").tag(FanProfile.custom)
                }
                .frame(width: 200)
                Spacer()
                Button { model.addPoint() } label: { Image(systemName: "plus") }
                    .disabled(model.points.count >= 12).help("Add point")
                Button { model.removePoint() } label: { Image(systemName: "minus") }
                    .disabled(model.points.count <= 2).help("Remove point")
            }

            CurveEditor(points: model.points,
                        currentCelsius: model.status?.controlCelsius,
                        rpmForFraction: model.rpm(forFraction:),
                        onChange: model.userEditedCurve)
                .frame(height: 220)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Temperature source")
                    Picker("", selection: $model.source) {
                        Text("CPU").tag(TemperatureSource.cpu)
                        Text("GPU").tag(TemperatureSource.gpu)
                        Text("Hottest").tag(TemperatureSource.hottest)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                }
                GridRow {
                    Text("Hysteresis")
                    Stepper("\(Int(model.hysteresis)) °C", value: $model.hysteresis, in: 0...10)
                }
                GridRow {
                    Text("Max ramp rate")
                    Picker("", selection: $model.slew) {
                        ForEach([100.0, 300, 600, 1200], id: \.self) { Text("\(Int($0)) rpm/s").tag($0) }
                    }
                    .labelsHidden().frame(width: 140)
                }
                GridRow {
                    Text("Only increase")
                    Toggle("Never go below the speed the system asks for (recommended)", isOn: $model.onlyIncrease)
                }
            }
            .font(.mhCallout)
        }
    }

    private var footer: some View {
        HStack {
            if let m = model.message { Text(m).font(.mhCaption).foregroundStyle(Palette.textMuted).lineLimit(2) }
            Spacer()
            Button("Return to System Control") { Task { await model.restoreAutomatic() } }
            Button("Apply") { Task { await model.apply() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isApplying)
        }
    }

    /// Commanded a speed but the fan stays far from it.
    private func commandIgnored(_ s: FanControlStatus) -> Bool {
        s.fans.contains { f in
            guard let c = f.commandedRPM, c > 0 else { return false }
            return abs(f.reading.actualRPM - c) / c > 0.35 && abs(f.reading.targetRPM - c) > 50
        }
    }
}

/// Temperature → speed curve with draggable control points.
private struct CurveEditor: View {
    let points: [FanCurve.Point]
    let currentCelsius: Double?
    let rpmForFraction: (Double) -> Double?
    let onChange: ([FanCurve.Point]) -> Void

    @State private var dragIndex: Int?

    private var sorted: [FanCurve.Point] { points.sorted { $0.celsius < $1.celsius } }

    var body: some View {
        Chart {
            ForEach(Array(sorted.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Temperature", p.celsius), y: .value("Speed", p.fraction * 100))
                    .interpolationMethod(.linear)
                PointMark(x: .value("Temperature", p.celsius), y: .value("Speed", p.fraction * 100))
                    .symbolSize(90)
            }
            if let t = currentCelsius {
                RuleMark(x: .value("Current", min(max(t, 20), 110)))
                    .foregroundStyle(Theme.orange)
                    .annotation(position: .top, alignment: .leading) {
                        Text(Fmt.celsius(t)).font(.mhCaption2).foregroundStyle(Theme.orange)
                    }
            }
        }
        .chartXScale(domain: 20...110)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .stride(by: 10)) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))°") } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(rpmForFraction(d / 100).map { "\(Int($0))" } ?? "\(Int(d))%")
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag($0.location, proxy: proxy, geo: geo) }
                        .onEnded { _ in dragIndex = nil })
            }
        }
        .accessibilityLabel("Fan curve")
        .accessibilityValue(sorted.map { String(localized: "\(Int($0.celsius))° \(Int($0.fraction * 100))%") }.joined(separator: ", "))
    }

    private func drag(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plot = proxy.plotFrame else { return }
        let origin = geo[plot].origin
        let local = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        var pts = sorted

        if dragIndex == nil {
            // Grab the nearest point within 24 pt.
            let distances = pts.enumerated().compactMap { i, p -> (Int, CGFloat)? in
                guard let pos = proxy.position(for: (p.celsius, p.fraction * 100)) else { return nil }
                return (i, hypot(pos.x - local.x, pos.y - local.y))
            }
            guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < 24 else { return }
            dragIndex = nearest.0
        }
        guard let i = dragIndex, let (c, y) = proxy.value(at: local, as: (Double, Double).self) else { return }

        // Keep points ordered: a point cannot pass its neighbours.
        let lo = i > 0 ? pts[i - 1].celsius + 1 : 20
        let hi = i < pts.count - 1 ? pts[i + 1].celsius - 1 : 110
        pts[i] = FanCurve.Point(celsius: min(max(c.rounded(), lo), hi), fraction: min(max(y / 100, 0), 1))
        onChange(pts)
    }
}
