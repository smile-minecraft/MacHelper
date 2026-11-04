import Foundation
import IOKit
import IOKit.pwr_mgt

/// System sleep / wake notifications for the daemon (IORegisterForSystemPower).
final class PowerObserver: @unchecked Sendable {
    // iokit_common_msg values; the C macros are not imported into Swift.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let onSleep: @Sendable () -> Void
    private let onWake: @Sendable () -> Void
    fileprivate var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(onSleep: @escaping @Sendable () -> Void, onWake: @escaping @Sendable () -> Void) {
        self.onSleep = onSleep
        self.onWake = onWake
    }

    func start(queue: DispatchQueue) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            Unmanaged<PowerObserver>.fromOpaque(refcon).takeUnretainedValue().handle(messageType, argument)
        }, &notifier)
        if let notifyPort { IONotificationPortSetDispatchQueue(notifyPort, queue) }
    }

    private func handle(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch type {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemWillSleep:
            onSleep()   // synchronous: fans are back on firmware before we acknowledge
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }
}
