import ArgumentParser
import Foundation
import Storage

struct MonitorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Background history recording (what the MacHelper user agent runs).",
        discussion: """
        Recording is switched on in the app (General → Background recording). When enabled,
        the recorder runs as the per-user agent; the app itself keeps recording while it is
        open. The agent reads the profile snapshot the app writes to
        ~/Library/Application Support/MacHelper/monitor-agent.json.
          machelper monitor --record    # run the recorder loop (what the background agent calls)
          machelper monitor --status    # show the last heartbeat the agent wrote
        """
    )

    @OptionGroup var output: OutputOptions

    @Flag(name: .long, help: "Run the recorder loop (what the background agent calls).")
    var record = false

    @Flag(name: .long, help: "Show the last heartbeat the recorder wrote.")
    var status = false

    func run() throws {
        if status {
            let heartbeat = MonitorAgentHeartbeatStore.load(from: MonitorAgentHeartbeatStore.defaultURL())
            if output.json {
                struct Out: Encodable { let schemaVersion = 1; let heartbeat: MonitorAgentHeartbeat? }
                try Output.json(Out(heartbeat: heartbeat))
            } else if let hb = heartbeat {
                Output.line("Last heartbeat: \(hb.lastHeartbeatAt.formatted()) (pid \(hb.pid)\(hb.lastError.map { ", last error: \($0)" } ?? ""))")
            } else {
                Output.line("No heartbeat recorded yet.")
            }
            return
        }
        if record {
            let history: MetricsHistory
            do {
                history = try MetricsHistory()
            } catch {
                Output.err("Couldn't open the history database: \(error.localizedDescription)")
                // Leave a failure in the heartbeat so the app can say why the recorder is
                // not running instead of showing a bare "stopped"; launchd retries later.
                let heartbeat = MonitorAgentHeartbeat(
                    pid: ProcessInfo.processInfo.processIdentifier,
                    lastHeartbeatAt: Date(),
                    lastError: "history database unavailable: \(error.localizedDescription)")
                try? MonitorAgentHeartbeatStore.save(heartbeat, to: MonitorAgentHeartbeatStore.defaultURL())
                throw ExitCode(1)
            }
            let hardware = MonitorHardwareSampler()
            // The collection switch lives in the shared database; read it once per process
            // sample so a toggle in the app reaches a running agent without a restart.
            let store = try? HistoryStore(readOnly: true)
            var recorder = MonitorAgentRecorder(
                history: history,
                sampler: hardware.sample,
                processCollection: store.map { store in
                    ProcessCollection(
                        sample: hardware.sampleProcesses,
                        isEnabled: { (try? store.isProcessCollectionEnabled()) ?? false })
                },
                seriesCollection: store.map { store in
                    SeriesCollection(
                        sample: hardware.sampleSeries,
                        isEnabled: { (try? store.isSeriesCollectionEnabled()) ?? false })
                })
            recorder.run()
            return
        }
        throw ValidationError("Pass --record or --status.")
    }
}
