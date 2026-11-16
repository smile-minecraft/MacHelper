import Foundation
import Metrics
import Observation

/// What the network page reads besides the store's throughput: the Wi-Fi link, the interface
/// details and per-app traffic. Everything here runs only while the page is visible; every
/// read is blocking and happens in a detached task.
@MainActor
@Observable
final class NetworkPanelModel {
    private(set) var wifi: WiFiReading?
    private(set) var details: NetworkDetailsSnapshot?
    private(set) var traffic: ProcessNetworkSnapshot?

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let detailsSampler = NetworkDetailsSampler()
    @ObservationIgnored private let trafficSampler = ProcessNetworkSampler()

    func start() {
        guard tasks.isEmpty else { return }
        let detailsSampler = detailsSampler
        let trafficSampler = trafficSampler
        trafficSampler.reset()
        tasks = [
            Task { [weak self] in
                while !Task.isCancelled {
                    let reading = await Task.detached(priority: .utility) { WiFiSampler.sample() }.value
                    guard !Task.isCancelled else { return }
                    self?.wifi = reading
                    try? await Task.sleep(for: .seconds(3))
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    let snapshot = await Task.detached(priority: .utility) { detailsSampler.snapshot() }.value
                    guard !Task.isCancelled else { return }
                    self?.details = snapshot
                    try? await Task.sleep(for: .seconds(30))
                }
            },
            // Each nettop snapshot takes about five seconds of wall time on its own, so the loop
            // only pauses briefly between them.
            Task { [weak self] in
                while !Task.isCancelled {
                    let snapshot = await Task.detached(priority: .utility) { trafficSampler.sample() }.value
                    guard !Task.isCancelled else { return }
                    if let snapshot { self?.traffic = snapshot }
                    try? await Task.sleep(for: .seconds(1))
                }
            },
        ]
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    /// The interface carrying the default IPv4 route, with its details when listed.
    var primary: (name: String, details: NetworkInterfaceDetails?)? {
        guard let details, case .interface(let name) = details.systemPrimaryIPv4 else { return nil }
        return (name, details.interface(named: name))
    }

    var isOffline: Bool {
        guard let details else { return false }
        return details.systemPrimaryIPv4 == .none && details.systemPrimaryIPv6 == .none
    }
}
