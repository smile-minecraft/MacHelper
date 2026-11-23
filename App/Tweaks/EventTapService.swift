@preconcurrency import CoreGraphics
import Foundation

/// One session-level tap shared by every event-driven tweak. The tap is installed only while at
/// least one such tweak is active, and the callback only classifies the event; window and app work
/// is scheduled back on the main actor.
/// The tap and its handler are only touched on the main run loop where the tap source is installed;
/// `@unchecked Sendable` only bridges the C callback back to that actor.
final class EventTapService: @unchecked Sendable {
    enum Outcome {
        case pass
        case suppress
        case suppressThen(@MainActor () -> Void)
    }

    /// Tags events this service reposts after a long press so they do not trip the tap again.
    static let postedMarker: Int64 = 0x4D48454C50455258

    private let handler: @MainActor @Sendable (CGEvent) -> Outcome
    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var source: CFRunLoopSource?

    init(handler: @escaping @MainActor @Sendable (CGEvent) -> Outcome) {
        self.handler = handler
    }

    var isInstalled: Bool { tap != nil }

    func install(mask: CGEventMask) {
        guard tap == nil else { return }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<EventTapService>.fromOpaque(refcon).takeUnretainedValue()
            return service.receive(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: CGEventTapPlacement(rawValue: 0)!,
                                           options: CGEventTapOptions(rawValue: 0)!,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = port
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func remove() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        self.source = nil
        self.tap = nil
    }

    deinit { remove() }

    /// Reposts a copy of a key event that the tap originally swallowed.
    static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: postedMarker)
        event.post(tap: .cghidEventTap)
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Values from CGEventTypes.h: the two out-of-band notifications that re-enable a tap.
        if type.rawValue == 0xFFFFFFFE || type.rawValue == 0xFFFFFFFF, let tap {
            // macOS stops a tap when its callback took too long; restart it instead of silently
            // losing the guard.
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.postedMarker {
            return Unmanaged.passUnretained(event)
        }
        guard Thread.isMainThread else {
            // Should not happen (the source is on the main run loop), but never swallow an event
            // on a thread where the main-actor rules cannot be evaluated.
            return Unmanaged.passUnretained(event)
        }
        let boxed = Unmanaged.passUnretained(event)
        return MainActor.assumeIsolated { decide(boxed) }
    }

    @MainActor
    private func decide(_ boxed: Unmanaged<CGEvent>) -> Unmanaged<CGEvent>? {
        let event = boxed.takeUnretainedValue()
        switch handler(event) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .suppress:
            return nil
        case .suppressThen(let work):
            Task { @MainActor in work() }
            return nil
        }
    }
}
