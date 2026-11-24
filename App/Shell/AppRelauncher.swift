import AppKit

enum AppRelauncher {
    /// Quits and opens this bundle again. The new copy starts only after this process has exited,
    /// so `open` cannot just reactivate it; if quitting is cancelled, nothing is opened.
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            i=0
            while /bin/kill -0 "$1" 2>/dev/null && [ "$i" -lt 150 ]; do /bin/sleep 0.2; i=$((i + 1)); done
            /bin/kill -0 "$1" 2>/dev/null || /usr/bin/open "$0"
            """,
            Bundle.main.bundlePath,
            String(ProcessInfo.processInfo.processIdentifier),
        ]
        try? process.run()
        NSApp.terminate(nil)
    }
}
