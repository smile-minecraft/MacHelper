import FanControl
import Foundation
import HelperProtocol
import Observation
import ServiceManagement

/// Editable fan settings plus the Helper's live status.
@MainActor
@Observable
final class FanControlModel {
    enum UIMode: String, CaseIterable, Identifiable {
        case automatic, fixed, curve
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: String(localized: "Automatic (System)")
            case .fixed: String(localized: "Fixed Speed")
            case .curve: String(localized: "Temperature Curve")
            }
        }
    }

    // Live
    private(set) var status: FanControlStatus?
    private(set) var helperStatus: SMAppService.Status = HelperClient.shared.status
    private(set) var message: String?
    private(set) var isApplying = false

    // Draft (what the user is editing)
    var mode: UIMode = .automatic
    var fixedFraction: Double = 0.5
    var profile: FanProfile = .balanced { didSet { if let c = profile.presetCurve { points = c.points } } }
    var points: [FanCurve.Point] = defaultPoints
    var source: TemperatureSource = .hottest
    var hysteresis: Double = 3
    var slew: Double = 300
    var onlyIncrease = true

    @ObservationIgnored private var draftLoaded = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let client = HelperClient.shared
    /// Lets automatic switching know which policy the user picked by hand.
    @ObservationIgnored var onUserApplied: ((FanPolicy) -> Void)?
    /// The curve the model starts with, and the one the editor shows when no custom curve has been
    /// saved yet.
    @ObservationIgnored nonisolated static let defaultPoints = FanCurve.balanced.points
    @ObservationIgnored nonisolated static let customCurveKey = "fan.customCurve.v1"

    /// Fan 0's range, for showing RPM next to fractions.
    var primaryRange: ClosedRange<Double>? {
        guard let f = status?.fans.first?.reading, f.maxRPM > f.minRPM else { return nil }
        return f.minRPM...f.maxRPM
    }

    func rpm(forFraction f: Double) -> Double? {
        primaryRange.map { $0.lowerBound + f * ($0.upperBound - $0.lowerBound) }
    }

    // MARK: Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        helperStatus = client.status
        guard helperStatus == .enabled else { status = nil; return }
        do {
            let s = try await client.fanControlStatus()
            status = s
            if !draftLoaded { loadDraft(from: s.policy); draftLoaded = true }
        } catch {
            message = "\(error)"
        }
    }

    // MARK: Draft ↔ policy

    private func loadDraft(from policy: FanPolicy) {
        switch policy.mode {
        case .automatic:
            mode = .automatic
        case .fixed(let f):
            mode = .fixed
            fixedFraction = f
        case .curve(let s):
            mode = .curve
            points = s.curve.points
            source = s.source
            hysteresis = s.hysteresis
            slew = s.maxSlewRPMPerSecond
            onlyIncrease = s.onlyIncrease
            profile = FanProfile.matching(s.curve)
            points = s.curve.points
        }
    }

    var draftPolicy: FanPolicy {
        switch mode {
        case .automatic: .automatic
        case .fixed: FanPolicy(mode: .fixed(fraction: fixedFraction))
        case .curve:
            FanPolicy(mode: .curve(CurveSettings(curve: FanCurve(points: points), source: source,
                                                 hysteresis: hysteresis, maxSlewRPMPerSecond: slew,
                                                 onlyIncrease: onlyIncrease)))
        }
    }

    /// Called by the curve editor after the user drags a point.
    func userEditedCurve(_ newPoints: [FanCurve.Point]) {
        points = newPoints
        if profile != .custom {
            // Switch to custom without the didSet overwriting the edit.
            let edited = newPoints
            profile = .custom
            points = edited
        }
        if let data = try? JSONEncoder().encode(newPoints) {
            UserDefaults.standard.set(data, forKey: Self.customCurveKey)
        }
    }

    func selectProfile(_ p: FanProfile) {
        if p == .custom,
           let data = UserDefaults.standard.data(forKey: Self.customCurveKey),
           let saved = try? JSONDecoder().decode([FanCurve.Point].self, from: data) {
            profile = .custom
            points = saved
        } else {
            profile = p
        }
    }

    /// Re-reads the saved custom curve after settings are imported, so the open curve editor
    /// shows the imported points. An import without a custom curve removes the saved one; the
    /// editor then shows the same default curve as a fresh model.
    func reload() {
        guard profile == .custom else { return }
        if let data = UserDefaults.standard.data(forKey: Self.customCurveKey),
           let saved = try? JSONDecoder().decode([FanCurve.Point].self, from: data) {
            points = saved
        } else {
            points = Self.defaultPoints
        }
    }

    func addPoint() {
        guard points.count < 12 else { return }
        let sorted = points.sorted { $0.celsius < $1.celsius }
        guard let (a, b) = zip(sorted, sorted.dropFirst()).max(by: { ($0.1.celsius - $0.0.celsius) < ($1.1.celsius - $1.0.celsius) })
        else { return }
        userEditedCurve(sorted + [FanCurve.Point(celsius: (a.celsius + b.celsius) / 2, fraction: (a.fraction + b.fraction) / 2)])
    }

    func removePoint() {
        guard points.count > 2 else { return }
        var sorted = points.sorted { $0.celsius < $1.celsius }
        sorted.remove(at: sorted.count / 2)
        userEditedCurve(sorted)
    }

    // MARK: Actions

    func apply() async {
        await send(draftPolicy)
    }

    func restoreAutomatic() async {
        mode = .automatic
        await send(.automatic)
    }

    private func send(_ policy: FanPolicy) async {
        isApplying = true
        defer { isApplying = false }
        do {
            try await client.applyFanPolicy(policy)
            onUserApplied?(policy)
            message = String(localized: "Applied")
            await refresh()
        } catch {
            message = "\(error)"
        }
    }
}
