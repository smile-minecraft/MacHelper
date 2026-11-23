import CoreGraphics
import Foundation

/// One session-level tap shared by every event-driven tweak.
///
/// A session tap sits in front of every keyboard and mouse event of the login session, so whoever
/// services it decides how quickly the whole Mac responds. The tap therefore runs on a thread of its
/// own with its own run loop, never on the main thread: a busy MacHelper window must not make typing
/// or clicking lag elsewhere. The filter it calls is synchronous, thread-safe and cheap; anything
/// that touches windows or apps is handed to the main queue by the behaviour itself.
final class EventTapService: @unchecked Sendable {
    enum Outcome: Sendable { case pass, suppress }
    typealias Filter = @Sendable (CGEventType, CGEvent) -> Outcome

    /// Tags events this service reposts after a long press so they do not trip the tap again.
    static let postedMarker: Int64 = 0x4D48454C50455258

    private let filter: Filter
    private let lock = NSLock()
    // Guarded by `lock`.
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var installedMask: CGEventMask = 0

    init(filter: @escaping Filter) {
        self.filter = filter
    }

    var isInstalled: Bool { lock.withLock { tap != nil } }

    /// Installs the tap for `mask`, replacing one installed for a different mask. Returns false when
    /// macOS refused the tap (no Accessibility permission).
    @discardableResult
    func install(mask: CGEventMask) -> Bool {
        if lock.withLock({ tap != nil && installedMask == mask }) { return true }
        remove()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<EventTapService>.fromOpaque(refcon).takeUnretainedValue().receive(type: type, event: event)
            }
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: callback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self.lock.withLock {
                self.tap = port
                self.runLoop = loop
                self.installedMask = mask
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "MacHelper event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        return isInstalled
    }

    func remove() {
        let (port, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer { tap = nil; runLoop = nil; installedMask = 0 }
            return (tap, runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    deinit { remove() }

    /// Reposts a copy of a key event that the tap originally swallowed.
    static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: postedMarker)
        event.post(tap: .cghidEventTap)
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS turns a tap off when a callback was too slow or on secure input; turn it back on
        // instead of silently losing the guard. These two notifications carry no real event.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ tap }) { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.postedMarker {
            return Unmanaged.passUnretained(event)
        }
        switch filter(type, event) {
        case .pass: return Unmanaged.passUnretained(event)
        case .suppress: return nil
        }
    }
}
