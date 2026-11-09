import AppKit
import SwiftUI

/// How often the mascot reacts; persisted in MascotSettingsStore.
enum MascotFrequency: String, CaseIterable, Codable, Sendable {
    case quiet, normal, lively

    var title: String {
        switch self {
        case .quiet: String(localized: "Quiet")
        case .normal: String(localized: "Normal")
        case .lively: String(localized: "Lively")
        }
    }

    var description: String {
        switch self {
        case .quiet: String(localized: "Reacts only to important events, with long pauses between reactions.")
        case .normal: String(localized: "Reacts to taps and system events at a steady pace.")
        case .lively: String(localized: "Reacts often and waves more often.")
        }
    }

    /// Cooldowns multiply by this: quiet waits longer, lively repeats sooner.
    var cooldownMultiplier: Double {
        switch self {
        case .quiet: 2.5
        case .normal: 1
        case .lively: 0.5
        }
    }

    /// Frames between idle waves (8 fps): quiet every 20 s, normal 10 s, lively 5 s.
    var idleWaveInterval: Int {
        switch self {
        case .quiet: 160
        case .normal: 80
        case .lively: 40
        }
    }
}

/// One built-in reaction to an interaction or a system event. All art is drawn from cells;
/// nothing loads external files.
enum MascotReaction: String, CaseIterable, Hashable, Sendable {
    case singleTap, doubleTap, hovered, dragged, longPressed
    case cpuHigh, memoryTight, diskLow, tempHot
    case batteryLow, batteryCharging
    case healthImproved, healthWorsened
    case cleanupFinished, helperConnected, helperDisconnected

    /// Higher wins when a system event and an interaction overlap.
    var priority: Int {
        switch self {
        case .helperDisconnected: 90
        case .cpuHigh, .tempHot: 85
        case .memoryTight, .diskLow: 80
        case .batteryLow: 75
        case .healthWorsened: 70
        case .doubleTap: 65
        case .longPressed: 62
        case .singleTap: 60
        case .dragged: 45
        case .hovered: 30
        case .cleanupFinished, .batteryCharging: 25
        case .healthImproved, .helperConnected: 20
        }
    }

    /// Seconds before the same reaction may show again (before the frequency multiplier).
    var cooldownSeconds: Double {
        switch self {
        case .singleTap: 0.5
        case .doubleTap: 1
        case .hovered: 0.5
        case .dragged: 0.2
        case .longPressed: 2
        case .cpuHigh: 8
        case .memoryTight: 10
        case .diskLow: 15
        case .tempHot: 10
        case .batteryLow: 20
        case .batteryCharging: 15
        case .healthImproved, .healthWorsened: 30
        case .cleanupFinished: 10
        case .helperConnected, .helperDisconnected: 10
        }
    }

    /// Momentary reactions show for this many frames at 8 fps.
    var durationFrames: Int {
        switch self {
        case .singleTap: 12
        case .doubleTap: 16
        case .hovered: 80
        case .dragged: 12
        case .longPressed: 16
        case .cpuHigh, .memoryTight, .diskLow, .tempHot, .batteryLow: 80
        case .batteryCharging: 24
        case .healthImproved, .healthWorsened: 24
        case .cleanupFinished: 24
        case .helperConnected, .helperDisconnected: 24
        }
    }

    /// Sustained conditions (CPU, memory, disk, temperature, battery) hold while true.
    var isSustained: Bool {
        switch self {
        case .cpuHigh, .memoryTight, .diskLow, .tempHot, .batteryLow: true
        default: false
        }
    }

    /// VoiceOver description: the slime's expression, never color alone.
    var accessibilityValue: String {
        switch self {
        case .singleTap: String(localized: "Cheering")
        case .doubleTap: String(localized: "Cheering loudly")
        case .hovered: String(localized: "Watching the pointer")
        case .dragged: String(localized: "Being dragged")
        case .longPressed: String(localized: "Holding steady")
        case .cpuHigh: String(localized: "Working hard")
        case .memoryTight: String(localized: "Tight, sweating")
        case .diskLow: String(localized: "Disk almost full")
        case .tempHot: String(localized: "Feeling hot, sweating")
        case .batteryLow: String(localized: "Battery low")
        case .batteryCharging: String(localized: "Charging")
        case .healthImproved: String(localized: "Health improved")
        case .healthWorsened: String(localized: "Health worse")
        case .cleanupFinished: String(localized: "Cleanup finished, celebrating")
        case .helperConnected: String(localized: "Helper connected")
        case .helperDisconnected: String(localized: "Helper disconnected")
        }
    }
}

/// An interaction's start, measured in the view's frame numbers (8 fps).
struct MascotInteraction: Hashable {
    var reaction: MascotReaction
    var startedAt: Int
    var shift: Int = 0
    var look: Int = 0
}

/// MacHelper's mascot: a blue pixel slime with eyes only (no nose, no mouth). It squashes and
/// bounces, blinks, and puts out two little hands to wave, cheer or point. Its face and actions
/// follow how the Mac is doing. Drawn cell by cell at 8 frames a second (pixel-art timing, cheap to
/// draw); still when Reduce Motion is on.
struct SlimeMascot: NSViewRepresentable {
    /// What the slime shows. Its color follows the level (blue fine, yellow needs a look, red bad);
    /// it holds up a sign pointing right when there is a suggested action next to it.
    struct Mood: Equatable {
        var level: StatusLevel = .good
        var holdsSign = false
        /// Nearly idle (only when everything is fine): dozing.
        var sleepy = false
        /// A system event reaction from OverviewView, or nil for the baseline mood.
        var reaction: MascotReaction?
    }

    let mood: Mood
    /// Size of one pixel in points.
    var cell: CGFloat = 4
    var frequency: MascotFrequency = .normal

    static let columns = 40, rows = 24
    static let fps = 8.0

    // An AppKit view with its own timer: each frame only redraws these pixels. Driving it from a
    // SwiftUI TimelineView re-ran layout of the whole window eight times a second (about 12% CPU).
    func makeNSView(context: Context) -> SlimeView { SlimeView(mood: mood, cell: cell, frequency: frequency) }

    func updateNSView(_ view: SlimeView, context: Context) {
        view.mood = mood
        view.cell = cell
        view.frequency = frequency
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SlimeView, context: Context) -> CGSize? {
        CGSize(width: CGFloat(Self.columns) * cell, height: CGFloat(Self.rows) * cell)
    }
}

final class SlimeView: NSView {
    var mood: SlimeMascot.Mood { didSet { if mood != oldValue { needsDisplay = true; updateAccessibility() } } }
    var cell: CGFloat { didSet { if cell != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var frequency: MascotFrequency { didSet { if frequency != oldValue { needsDisplay = true } } }
    private let start = Date()
    private var timer: Timer?
    private var colors: [Color: CGColor] = [:]
    /// The pose on screen. Most frames repeat it (the breathing cycle is slow), so the timer only
    /// asks for a redraw when the pose actually changes.
    private var shownPose: SlimePose?
    /// Each pose rendered once at the screen's pixel size; a frame then draws one image instead of
    /// a few hundred rectangles.
    private var images: [SlimePose: CGImage] = [:]
    private var imageScale: CGFloat = 0

    // Interaction starts as wall-clock dates so expiry still works with Reduce Motion (frame 0).
    private var tapDate: Date?
    private var doubleDate: Date?
    private var hoverDate: Date?
    private var hoverLook = 0
    private var isHovered = false
    private var dragDate: Date?
    private var dragShift = 0
    private var pressDate: Date?
    private var longPressDate: Date?
    private var lastTapDate: Date?
    private var lastInteraction: [MascotReaction: Date] = [:]

    init(mood: SlimeMascot.Mood, cell: CGFloat, frequency: MascotFrequency) {
        self.mood = mood
        self.cell = cell
        self.frequency = frequency
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "MacHelper mascot"))
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("not used") }


    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(SlimeMascot.columns) * cell, height: CGFloat(SlimeMascot.rows) * cell)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var currentFrame: Int { reduceMotion ? 0 : Int(Date().timeIntervalSince(start) * SlimeMascot.fps) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        // Fire in the middle of each frame, not on its edge: a tick that lands a hair early on a
        // boundary samples the previous frame, and the next one then skips a frame (visible stutter).
        let elapsed = Date().timeIntervalSince(start) * SlimeMascot.fps
        let firstFire = start.addingTimeInterval((elapsed.rounded(.down) + 1.5) / SlimeMascot.fps)
        let t = Timer(fire: firstFire, interval: 1 / SlimeMascot.fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        // Nothing to do while hidden, covered or with Reduce Motion on.
        guard let window, window.isVisible, window.occlusionState.contains(.visible), !reduceMotion else { return }
        if currentPose != shownPose { needsDisplay = true }
    }

    private var currentPose: SlimePose {
        let frame = currentFrame
        func inter(_ reaction: MascotReaction, _ date: Date?, shift: Int = 0, look: Int = 0) -> MascotInteraction? {
            guard let date else { return nil }
            let age = Int(Date().timeIntervalSince(date) * SlimeMascot.fps)
            return MascotInteraction(reaction: reaction, startedAt: frame - age, shift: shift, look: look)
        }
        var best: MascotInteraction?
        let candidates = [
            inter(.singleTap, tapDate),
            inter(.doubleTap, doubleDate),
            inter(.hovered, isHovered ? hoverDate : nil, look: hoverLook),
            inter(.dragged, dragDate, shift: dragShift),
            inter(.longPressed, longPressDate),
        ].compactMap { $0 }
        for cand in candidates where best == nil || cand.reaction.priority > best!.reaction.priority {
            best = cand
        }
        return SlimePose.make(mood: mood, frame: frame, tappedAt: nil, interaction: best, frequency: frequency, reduceMotion: reduceMotion)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pose = currentPose
        shownPose = pose
        guard let image = image(for: pose) else { return }
        // The view is flipped; CGImages draw bottom-up, so flip back for the draw.
        let size = CGSize(width: CGFloat(SlimeMascot.columns) * cell, height: CGFloat(SlimeMascot.rows) * cell)
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    private func image(for pose: SlimePose) -> CGImage? {
        let scale = (window?.backingScaleFactor ?? 2) * cell
        if scale != imageScale { images.removeAll(); imageScale = scale }
        if let cached = images[pose] { return cached }
        let px = max(1, Int(scale.rounded()))
        let w = SlimeMascot.columns * px, h = SlimeMascot.rows * px
        guard let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        SlimeRenderer.paint(pose) { x, y, color in
            bitmap.setFillColor(cgColor(color))
            bitmap.fill(CGRect(x: x * px, y: h - (y + 1) * px, width: px, height: px))
        }
        guard let image = bitmap.makeImage() else { return nil }
        // A mood has a few dozen poses; keep the set bounded if moods change a lot.
        if images.count > 160 { images.removeAll() }
        images[pose] = image
        return image
    }

    private func cgColor(_ color: Color) -> CGColor {
        if let c = colors[color] { return c }
        let c = NSColor(color).cgColor
        colors[color] = c
        return c
    }

    private func scheduleRefresh(after seconds: Double) {
        let work = DispatchWorkItem { [weak self] in
            self?.needsDisplay = true
            self?.updateAccessibility()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Interaction cooldown, scaled by frequency. Returns false while still cooling.
    private func canTrigger(_ reaction: MascotReaction) -> Bool {
        let now = Date()
        let cooldown = reaction.cooldownSeconds * frequency.cooldownMultiplier
        if let last = lastInteraction[reaction], now.timeIntervalSince(last) < cooldown { return false }
        lastInteraction[reaction] = now
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            if canTrigger(.doubleTap) { doubleDate = Date(); scheduleRefresh(after: Double(MascotReaction.doubleTap.durationFrames) / SlimeMascot.fps) }
        } else {
            if let last = lastTapDate, Date().timeIntervalSince(last) < 0.4 {
                if canTrigger(.doubleTap) { doubleDate = Date(); scheduleRefresh(after: Double(MascotReaction.doubleTap.durationFrames) / SlimeMascot.fps) }
            } else if canTrigger(.singleTap) {
                tapDate = Date()
                scheduleRefresh(after: Double(MascotReaction.singleTap.durationFrames) / SlimeMascot.fps)
            }
            lastTapDate = Date()
        }
        pressDate = Date()
        // Long press: if the pointer stays down for half a second, trade the tap for holding steady.
        let pressed = pressDate
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard let self, self.pressDate == pressed else { return }
            guard self.canTrigger(.longPressed) else { return }
            self.longPressDate = Date()
            self.needsDisplay = true
            self.updateAccessibility()
            self.scheduleRefresh(after: Double(MascotReaction.longPressed.durationFrames) / SlimeMascot.fps)
        }
        needsDisplay = true
        updateAccessibility()
    }

    override func mouseUp(with event: NSEvent) {
        pressDate = nil
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if canTrigger(.hovered) { hoverDate = Date() } else { hoverDate = nil }
        hoverLook = convert(event.locationInWindow, from: nil).x < bounds.width / 2 ? -1 : 1
        needsDisplay = true
        updateAccessibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoverDate = nil
        needsDisplay = true
        updateAccessibility()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isHovered else { return }
        // Re-arm hover once its cooldown passes while the pointer is still over the slime.
        if hoverDate == nil, canTrigger(.hovered) {
            hoverDate = Date()
            needsDisplay = true
            updateAccessibility()
        }
        let look = convert(event.locationInWindow, from: nil).x < bounds.width / 2 ? -1 : 1
        if look != hoverLook { hoverLook = look; needsDisplay = true }
    }

    override func mouseDragged(with event: NSEvent) {
        guard bounds.width > 0 else { return }
        let active = dragDate != nil && Date().timeIntervalSince(dragDate!) < Double(MascotReaction.dragged.durationFrames) / SlimeMascot.fps
        if !active, !canTrigger(.dragged) { return }
        dragDate = Date()
        // The slime leans toward the pointer; the renderer keeps it inside the grid.
        let fraction = convert(event.locationInWindow, from: nil).x / bounds.width - 0.5
        dragShift = max(-4, min(4, Int((fraction * 8).rounded())))
        needsDisplay = true
        updateAccessibility()
        scheduleRefresh(after: Double(MascotReaction.dragged.durationFrames) / SlimeMascot.fps)
    }

    /// The reaction the slime actually shows, mirroring SlimePose.make's priority choice.
    private var displayedReaction: MascotReaction? {
        let now = Date()
        var best: MascotReaction?
        func consider(_ reaction: MascotReaction, _ date: Date?) {
            guard let date else { return }
            if reaction == .hovered {
                guard isHovered, now.timeIntervalSince(date) < Double(reaction.durationFrames) / SlimeMascot.fps else { return }
            } else if now.timeIntervalSince(date) >= Double(reaction.durationFrames) / SlimeMascot.fps { return }
            if best == nil || reaction.priority > best!.priority { best = reaction }
        }
        consider(.hovered, hoverDate)
        consider(.singleTap, tapDate)
        consider(.doubleTap, doubleDate)
        consider(.dragged, dragDate)
        consider(.longPressed, longPressDate)
        if let system = mood.reaction, best == nil || system.priority >= best!.priority { return system }
        return best
    }

    private func updateAccessibility() {
        if let reaction = displayedReaction {
            setAccessibilityValue(reaction.accessibilityValue)
            return
        }
        let value: String = switch mood.level {
        case .critical: String(localized: "Sweating")
        case .attention: mood.holdsSign ? String(localized: "Pointing at the suggested action") : String(localized: "Alert")
        case .good: mood.sleepy ? String(localized: "Dozing") : String(localized: "Relaxed")
        }
        setAccessibilityValue(value)
    }
}

/// One frame: body shape, eyes, hands and extras, in grid cells.
struct SlimePose: Hashable {
    enum Eyes: Hashable { case open, happy, closed, squint, dizzy, wide }
    enum Hand: Hashable {
        case hidden
        /// A mitt at the side: 1 = peeking out, 2 = all the way out.
        case out(Int)
        /// A mitt raised beside the body (1–2 cells up), lifted by `lift` more while waving.
        case up(Int, lift: Int)
    }

    var halfWidth = 10
    var height = 11
    /// Upward offset of the whole body (jumping).
    var jump = 0
    /// Sideways offset (wobbling).
    var shift = 0
    var eyes: Eyes = .open
    /// Eyes looking left (-1) or right (1).
    var look = 0
    var left: Hand = .hidden
    var right: Hand = .hidden
    /// Sweat drop progress 0…5 (nil = none).
    var sweat: Int?
    /// Floating "Z" progress 0…7 (nil = none).
    var snore: Int?
    /// Lightning bolt progress 0…7 (nil = none).
    var bolt: Int?
    /// Sparkle progress 0…7 (nil = none).
    var spark: Int?
    /// Body color.
    var tint: StatusLevel = .good
    /// A sign with a right arrow held up in the right hand, poked this many cells to the right (nil = no sign).
    var sign: Int?

    static func make(mood: SlimeMascot.Mood, frame f: Int, tappedAt: Int?, interaction: MascotInteraction? = nil, frequency: MascotFrequency = .normal, reduceMotion: Bool = false) -> SlimePose {
        var p = SlimePose()
        // Breathing: a slow squash and stretch.
        let phase = reduceMotion ? 0 : f % 16
        let squash = phase < 4 ? 0 : phase < 6 ? 1 : phase < 12 ? 0 : phase < 14 ? -1 : 0
        p.halfWidth = 10 + squash
        p.height = 11 - squash
        let blinking = !reduceMotion && f % 36 < 2
        let still = reduceMotion

        // A tap from the old call shape still works (snapshot and preview callers).
        var resolved = interaction
        if resolved == nil, let t = tappedAt {
            resolved = MascotInteraction(reaction: .singleTap, startedAt: t)
        }
        if let inter = resolved {
            let age = f - inter.startedAt
            if age < 0 || age >= inter.reaction.durationFrames { resolved = nil }
        }

        let system = mood.reaction
        var chosen: MascotReaction?
        var chosenShift = 0
        var chosenLook = 0
        /// Frames since the chosen interaction began; system reactions loop on the clock instead.
        var chosenAge: Int?
        if let s = system, let i = resolved {
            if s.priority >= i.reaction.priority {
                chosen = s
            } else {
                chosen = i.reaction
                chosenShift = i.shift
                chosenLook = i.look
                chosenAge = f - i.startedAt
            }
        } else if let s = system {
            chosen = s
        } else if let i = resolved {
            chosen = i.reaction
            chosenShift = i.shift
            chosenLook = i.look
            chosenAge = f - i.startedAt
        }

        if let c = chosen {
            p.tint = mood.level
            // Reduce Motion freezes displacement and animated extras; only expression changes.
            let displacement: (Int, Int) -> (Int, Int) = { jump, shift in still ? (0, 0) : (jump, shift) }
            /// Applies one frame of a hop (crouch, rise, hang, fall, land) to the body.
            func hop(_ k: Int, height: Int) {
                guard !still else { return }
                let (jump, squash) = Self.hop(k, height: height)
                p.jump = jump
                p.halfWidth = 10 + squash
                p.height = 11 - squash
            }
            let age = chosenAge ?? 0
            let remaining = c.durationFrames - age
            /// Mitts rise over two frames on the way in and drop a step on the way out.
            func raisedHands() -> Hand {
                if still { return .up(2, lift: 0) }
                if chosenAge != nil, age < 1 { return .out(2) }
                if chosenAge != nil, age < 2 || remaining <= 2 { return .up(1, lift: 0) }
                return .up(2, lift: 0)
            }
            switch c {
            case .singleTap:
                hop(age, height: 2)
                p.eyes = age < 1 && !still ? .closed : .happy
                p.left = raisedHands(); p.right = raisedHands()
            case .doubleTap:
                // Two hops: a big one, then a smaller one.
                let big = Self.hopFrames(height: 3).count
                hop(age < big ? age : age - big, height: age < big ? 3 : 2)
                p.eyes = age < 1 && !still ? .closed : .wide
                p.left = raisedHands(); p.right = raisedHands()
                if !still, age >= big, (age - big) % 2 == 0 { p.left = .up(2, lift: 1) }
            case .hovered:
                p.eyes = .happy
                p.look = chosenLook
                // Peek, then lift the mitt and give a short wave.
                p.right = still ? .up(1, lift: 0) : age < 1 ? .out(1) : .up(1, lift: age < 8 ? (age / 2) % 2 : 0)
                p.left = .out(1)
            case .dragged:
                let (_, shift) = displacement(0, chosenShift)
                p.shift = shift
                p.eyes = .dizzy
                p.left = .out(2); p.right = .out(2)
            case .longPressed:
                p.halfWidth = 11; p.height = 12
                p.eyes = .squint
                p.left = .out(2); p.right = .out(2)
            case .cpuHigh:
                // Fast heavy breathing, wide eyes, fresh sweat.
                p.halfWidth = 10 + (!still && f % 8 < 4 ? 1 : 0)
                p.height = 11 - (!still && f % 8 < 4 ? 1 : 0)
                p.eyes = .wide
                p.sweat = still ? 0 : (f / 2) % 6
                p.left = .out(1); p.right = .out(1)
            case .memoryTight:
                // Compressed, squinting, slow sweat.
                p.halfWidth = 9; p.height = 11
                p.eyes = .squint
                p.sweat = still ? 1 : (f / 4) % 6
            case .diskLow:
                // Wobbling with dizzy eyes.
                let wobble = still ? 0 : (f % 8 < 4 ? 1 : -1)
                let (_, shift) = displacement(0, wobble)
                p.shift = shift
                p.eyes = .dizzy
                p.left = .out(1); p.right = .out(1)
            case .tempHot:
                p.eyes = .squint
                p.sweat = still ? 0 : (f / 2) % 6
                p.left = .out(1)
                if !mood.holdsSign { p.right = .out(1) }
            case .batteryLow:
                p.halfWidth = 10; p.height = 10
                p.eyes = .closed
                p.left = .out(1); p.right = .out(1)
                p.snore = still ? 0 : (f / 2) % 8
            case .batteryCharging:
                p.eyes = .happy
                p.left = .up(2, lift: 0); p.right = .up(2, lift: 0)
                p.bolt = still ? 0 : f % 8
            case .healthImproved:
                hop(f % 12, height: 2)
                p.eyes = .happy
                p.left = .up(2, lift: 0); p.right = .up(2, lift: 0)
                p.spark = still ? 0 : f % 8
            case .healthWorsened:
                p.eyes = .dizzy
                p.sweat = still ? 0 : (f / 4) % 6
                p.left = .out(1); p.right = .out(1)
            case .cleanupFinished:
                hop(f % 12, height: 2)
                p.eyes = .happy
                p.left = .up(2, lift: 0); p.right = .up(2, lift: 0)
                p.spark = still ? 0 : f % 8
            case .helperConnected:
                p.eyes = .happy
                p.look = 1
                p.right = .up(min(2, 1), lift: still ? 0 : (f / 2) % 2)
                p.bolt = still ? 0 : f % 8
            case .helperDisconnected:
                p.eyes = .dizzy
                p.sweat = still ? 2 : (f / 4) % 6
                p.left = .out(1); p.right = .out(1)
            }
            return p
        }

        p.tint = mood.level
        switch mood.level {
        case .critical:
            // Bad: red, > < eyes, sweating, breathing hard.
            p.eyes = .squint
            p.halfWidth = 10 + (f % 8 < 4 ? 1 : 0)
            p.height = 11 - (f % 8 < 4 ? 1 : 0)
            p.sweat = (f / 2) % 6
            p.left = .out(1)
            if !mood.holdsSign { p.right = .out(1) }
        case .attention:
            p.eyes = blinking ? .closed : .open
            p.look = mood.holdsSign ? 1 : 0
        case .good:
            if mood.sleepy {
                p.eyes = .closed
                p.halfWidth = 10 + (f % 32 < 16 ? 1 : 0)
                p.height = 11 - (f % 32 < 16 ? 1 : 0)
                p.snore = (f / 2) % 8
            } else {
                p.eyes = blinking ? .closed : .open
                // Idle wave, spaced by the selected frequency.
                let interval = frequency.idleWaveInterval
                let cycle = f % interval
                if cycle >= interval - 24, !mood.holdsSign {
                    let k = cycle - (interval - 24)
                    p.right = .up(min(2, k + 1, interval - cycle), lift: (k / 2) % 2)
                    p.eyes = .happy
                }
            }
        }
        if mood.holdsSign {
            // The sign is held up in the right mitt; every 4 s it pokes to the right twice.
            p.right = .up(2, lift: 0)
            let k = f % 32
            p.sign = (k < 2 || (k >= 4 && k < 6)) ? 1 : 0
        }
        return p
    }
}

extension SlimePose {
    /// Jump height and squash (+1 wide and short, -1 narrow and tall) per frame of a hop.
    static func hopFrames(height: Int) -> [(jump: Int, squash: Int)] {
        let up = (1..<height).map { (jump: $0, squash: -1) }
        return [(0, 1)] + up + [(height, 0), (height, 0)] + up.reversed() + [(0, 1), (0, 0)]
    }

    /// One frame of a hop; past its end the slime rests on the ground.
    static func hop(_ k: Int, height: Int) -> (jump: Int, squash: Int) {
        let frames = hopFrames(height: height)
        return k >= 0 && k < frames.count ? frames[k] : (0, 0)
    }
}

enum SlimeRenderer {
    /// Body colors by level, independent of the theme: blue when fine, yellow when something
    /// needs a look, red when it's bad.
    struct Skin { let outline, dark, base, light: Color }
    static func skin(_ level: StatusLevel) -> Skin {
        switch level {
        case .good: Skin(outline: Color(red: 0.16, green: 0.27, blue: 0.58), dark: Color(red: 0.27, green: 0.52, blue: 0.91),
                         base: Color(red: 0.42, green: 0.66, blue: 1.0), light: Color(red: 0.72, green: 0.85, blue: 1.0))
        case .attention: Skin(outline: Color(red: 0.48, green: 0.33, blue: 0.06), dark: Color(red: 0.85, green: 0.60, blue: 0.12),
                              base: Color(red: 0.97, green: 0.77, blue: 0.27), light: Color(red: 1.0, green: 0.91, blue: 0.62))
        case .critical: Skin(outline: Color(red: 0.48, green: 0.12, blue: 0.12), dark: Color(red: 0.85, green: 0.27, blue: 0.25),
                             base: Color(red: 0.96, green: 0.43, blue: 0.40), light: Color(red: 1.0, green: 0.71, blue: 0.68))
        }
    }
    static let eye = Color(red: 0.23, green: 0.24, blue: 0.28)   // dark grey, softer than black
    static let white = Color.white
    static let sweat = Color(red: 0.70, green: 0.88, blue: 1.0)
    static let wood = Color(red: 0.95, green: 0.84, blue: 0.63)
    static let woodEdge = Color(red: 0.42, green: 0.27, blue: 0.14)
    static let arrow = Color(red: 0.36, green: 0.22, blue: 0.10)
    static let bolt = Color(red: 1.0, green: 0.85, blue: 0.25)
    static let spark = Color(red: 1.0, green: 0.95, blue: 0.65)

    enum Cell { case body, hand, outline, eye, white, sweat, snore, stick, board, boardEdge, arrow, bolt, spark }

    static func draw(_ p: SlimePose, in ctx: GraphicsContext, cell: CGFloat) {
        paint(p) { x, y, color in
            ctx.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)), with: .color(color))
        }
    }

    /// Calls `fill` once per painted cell (column, row, color), top-left origin.
    static func paint(_ p: SlimePose, fill: (Int, Int, Color) -> Void) {
        let w = SlimeMascot.columns, h = SlimeMascot.rows
        var grid = [[Cell?]](repeating: [Cell?](repeating: nil, count: w), count: h)
        func put(_ x: Int, _ y: Int, _ c: Cell) { if x >= 0, x < w, y >= 0, y < h { grid[y][x] = c } }

        let cx = Double(w) / 2 + Double(p.shift)
        let bottom = Double(h - 1 - p.jump)          // bottom edge of the body
        let hw = Double(p.halfWidth), ht = Double(p.height)

        // Body: a dome with a flat, slightly rounded bottom.
        for y in 0..<h {
            for x in 0..<w {
                let u = abs(Double(x) + 0.5 - cx) / hw
                let v = (bottom - (Double(y) + 0.5)) / ht
                guard v > 0, v <= 1 else { continue }
                if pow(u, 2.4) + v * v <= 1, u <= 1 - max(0, 0.6 / ht - v) * 0.8 { grid[y][x] = .body }
            }
        }

        // Hands: short, chubby 3×3 mitts stuck right onto the side of the body, no arm.
        let armY = Int(bottom - ht * 0.34)
        func blob(_ hx: Int, _ hy: Int) {
            for dx in -1...1 { for dy in -1...1 { put(hx + dx, hy + dy, .hand) } }
        }
        func hand(_ pose: SlimePose.Hand, side: Int) {
            // First column outside the body on this side.
            let edge = side > 0 ? Int(cx + hw - 0.5) + 1 : Int(cx - hw + 0.5) - 1
            switch pose {
            case .hidden: return
            case .out(let reach):
                // 1: peeking out; 2: all the way out, still touching the body.
                guard reach > 0 else { return }
                blob(edge + side * (min(reach, 2) - 1), armY)
            case .up(let reach, let lift):
                // Raised beside the body: a one-cell nub up to the mitt.
                guard reach > 0 else { return }
                let hy = armY - 1 - min(reach, 2) - lift
                put(edge - side, armY - 1, .hand)
                put(edge, armY - 1, .hand)
                blob(edge, hy)
            }
        }
        hand(p.left, side: -1)
        hand(p.right, side: 1)

        // Outline around body and hands.
        let solid = grid
        for y in 0..<h {
            for x in 0..<w where solid[y][x] == nil {
                let n = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { dx, dy in
                    let nx = x + dx, ny = y + dy
                    return nx >= 0 && nx < w && ny >= 0 && ny < h && solid[ny][nx] != nil
                }
                if n { grid[y][x] = .outline }
            }
        }

        // The sign: a stick up from the right mitt and a wooden board with a right arrow.
        if let poke = p.sign, case .up(let reach, let lift) = p.right {
            let edge = Int(cx + hw - 0.5) + 1
            let handTop = armY - 1 - min(reach, 2) - lift - 1
            let sx = edge + poke
            for y in (handTop - 2)..<handTop { put(sx, y, .stick) }
            let bx0 = sx - 4, bx1 = sx + 8, by1 = handTop - 3, by0 = by1 - 8
            for y in by0...by1 {
                for x in bx0...bx1 { put(x, y, (y == by0 || y == by1 || x == bx0 || x == bx1) ? .boardEdge : .board) }
            }
            // A right arrow: a shaft and a three-step head at its tip.
            let my = (by0 + by1) / 2, tip = bx1 - 2
            for x in (bx0 + 2)...tip { put(x, my, .arrow) }
            for k in 1...3 { put(tip - k, my - k, .arrow); put(tip - k, my + k, .arrow) }
        }

        // Eyes (the whole face: no nose, no mouth).
        let gap = max(2, Int((hw * 0.22).rounded()))   // eyes close together: a cuter, rounder face
        let eyeY = Int(bottom - ht * 0.55)
        for side in [-1, 1] {
            let ex = Int(cx) + side * gap - (side < 0 ? 1 : 0) + p.look
            eyes(p.eyes, at: ex, eyeY, mirror: side > 0, put: put)
        }
        // Shine on the dome.
        let top = Int(bottom - ht)
        put(Int(cx - hw * 0.55), top + 3, .white)
        put(Int(cx - hw * 0.55) + 1, top + 2, .white)

        if let s = p.sweat {
            let sx = Int(cx + hw * 0.75), sy = top + 1 + s
            put(sx, sy, .sweat); put(sx, sy + 1, .sweat)
        }
        if let z = p.snore {
            // A 4×4 "Z" rising from the top right.
            let zx = Int(cx + hw * 0.6) + z / 3, zy = top - 2 - z / 2
            for (dx, dy) in [(0, 0), (1, 0), (2, 0), (3, 0), (2, 1), (1, 2), (0, 3), (1, 3), (2, 3), (3, 3)] { put(zx + dx, zy + dy, .snore) }
        }
        if let b = p.bolt {
            // A small lightning bolt above the dome, bobbing with the progress.
            let bx = Int(cx), by = max(1, top - 6 + b / 2)
            for (dx, dy) in [(0, 0), (1, 0), (-1, 1), (0, 1), (0, 2), (1, 2), (-1, 3), (0, 3)] { put(bx + dx, by + dy, .bolt) }
        }
        if let s = p.spark {
            // Three four-point sparkles around the slime, offset by the progress.
            let off = s % 3
            for (sx, sy) in [(Int(cx - hw) - 2, top + 3 + off), (Int(cx + hw) + 2, top + 3 + (off + 1) % 3), (Int(cx), max(1, top - 3 + off))] {
                put(sx, sy, .spark); put(sx - 1, sy, .spark); put(sx + 1, sy, .spark); put(sx, sy - 1, .spark); put(sx, sy + 1, .spark)
            }
        }

        // Paint: bevel the body (light top-left edge, dark bottom-right edge and the bottom rows).
        let skin = Self.skin(p.tint)
        let dark = skin.dark, base = skin.base, light = skin.light, outline = skin.outline
        for y in 0..<h {
            for x in 0..<w {
                guard let c = grid[y][x] else { continue }
                let color: Color
                switch c {
                case .body, .hand:
                    let isBody = { (xx: Int, yy: Int) -> Bool in
                        xx >= 0 && xx < w && yy >= 0 && yy < h && (grid[yy][xx] == .body || grid[yy][xx] == .hand
                            || grid[yy][xx] == .eye || grid[yy][xx] == .white)
                    }
                    if !isBody(x, y + 1) || !isBody(x + 1, y) || Double(y) > bottom - 2.5 { color = dark }
                    else if !isBody(x, y - 1) || !isBody(x - 1, y) { color = light }
                    else { color = base }
                case .outline: color = outline
                case .eye: color = eye
                case .white: color = white
                case .sweat: color = sweat
                case .snore: color = light
                case .stick, .boardEdge: color = woodEdge
                case .board: color = wood
                case .arrow: color = arrow
                case .bolt: color = bolt
                case .spark: color = spark
                }
                fill(x, y, color)
            }
        }
    }

    /// Eye shapes on a 3×3 area whose top-left is (x, y - 1).
    private static func eyes(_ e: SlimePose.Eyes, at x: Int, _ y: Int, mirror: Bool, put: (Int, Int, Cell) -> Void) {
        func m(_ dx: Int) -> Int { mirror ? 1 - dx : dx }
        switch e {
        case .open:
            for dy in 0...2 { for dx in 0...1 { put(x + dx, y - 1 + dy, .eye) } }
        case .wide:
            for dy in 0...2 { for dx in -1...1 { put(x + dx, y - 1 + dy, .eye) } }
        case .happy:   // ^ ^
            put(x - 1, y + 1, .eye); put(x, y, .eye); put(x + 1, y, .eye); put(x + 2, y + 1, .eye)
        case .closed:
            put(x, y + 1, .eye); put(x + 1, y + 1, .eye)
        case .squint:  // > <
            put(x + m(0), y - 1, .eye); put(x + m(1), y, .eye); put(x + m(0), y + 1, .eye)
        case .dizzy:   // x x
            for (dx, dy) in [(-1, -1), (1, -1), (0, 0), (-1, 1), (1, 1)] { put(x + dx, y + dy, .eye) }
        }
    }
}
