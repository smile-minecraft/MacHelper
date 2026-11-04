import Foundation
import HelperProtocol
import os
import SMCKit

// Root LaunchDaemon registered by the app via SMAppService.daemon.
// Lives at MacHelper.app/Contents/MacOS/MacHelperHelper.

let log = Logger(subsystem: HelperConstants.helperBundleIdentifier, category: "main")

let smc: SMC
do {
    smc = try SMC()
} catch {
    log.fault("Cannot open SMC: \(String(describing: error), privacy: .public)")
    exit(1)
}
let driver = FanDriver(smc: smc)

// Safety: if a previous run died while holding manual control, give the fans back now.
if driver.readFans().contains(where: { $0.mode == .manual }) {
    log.notice("Fans found in manual mode at startup; restoring automatic")
    driver.restoreAllAutomatic()
}

// Safety: restore automatic on termination (launchd sends SIGTERM on unload / shutdown).
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    log.notice("SIGTERM: restoring automatic fan control")
    driver.restoreAllAutomatic()
    exit(0)
}
termSource.resume()

// Fan policy loop. Curves persist and keep running without the app.
let engine = FanControlEngine(driver: driver)
engine.start()

let powerObserver = PowerObserver(onSleep: { engine.willSleep() }, onWake: { engine.didWake() })
powerObserver.start(queue: DispatchQueue(label: "com.machelper.helper.power"))

let delegate = ListenerDelegate(driver: driver, engine: engine, clientRequirement: { ClientVerifier.requirement() })
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
log.notice("Helper listening on \(HelperConstants.machServiceName, privacy: .public)")
dispatchMain()
