import AppKit
import SwiftUI

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
    }

    let mood: Mood
    /// Size of one pixel in points.
    var cell: CGFloat = 4

    static let columns = 40, rows = 24
    static let fps = 8.0

    // An AppKit view with its own timer: each frame only redraws these pixels. Driving it from a
    // SwiftUI TimelineView re-ran layout of the whole window eight times a second (about 12% CPU).
    func makeNSView(context: Context) -> SlimeView { SlimeView(mood: mood, cell: cell) }

    func updateNSView(_ view: SlimeView, context: Context) {
        view.mood = mood
        view.cell = cell
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SlimeView, context: Context) -> CGSize? {
        CGSize(width: CGFloat(Self.columns) * cell, height: CGFloat(Self.rows) * cell)
    }
}

final class SlimeView: NSView {
    var mood: SlimeMascot.Mood { didSet { if mood != oldValue { needsDisplay = true; updateAccessibility() } } }
    var cell: CGFloat { didSet { if cell != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    private let start = Date()
    private var tappedAt: Int?
    private var timer: Timer?
    private var colors: [Color: CGColor] = [:]

    init(mood: SlimeMascot.Mood, cell: CGFloat) {
        self.mood = mood
        self.cell = cell
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

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var currentFrame: Int { reduceMotion ? 0 : Int(Date().timeIntervalSince(start) * SlimeMascot.fps) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1 / SlimeMascot.fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        // Nothing to do while hidden, covered or with Reduce Motion on.
        guard let window, window.isVisible, window.occlusionState.contains(.visible), !reduceMotion else { return }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pose = SlimePose.make(mood: mood, frame: currentFrame, tappedAt: reduceMotion ? nil : tappedAt)
        let c = cell
        SlimeRenderer.paint(pose) { x, y, color in
            ctx.setFillColor(cgColor(color))
            ctx.fill(CGRect(x: CGFloat(x) * c, y: CGFloat(y) * c, width: c, height: c))
        }
    }

    private func cgColor(_ color: Color) -> CGColor {
        if let c = colors[color] { return c }
        let c = NSColor(color).cgColor
        colors[color] = c
        return c
    }

    override func mouseDown(with event: NSEvent) {
        tappedAt = Int(Date().timeIntervalSince(start) * SlimeMascot.fps)
        needsDisplay = true
    }

    private func updateAccessibility() {
        let value: String = switch mood.level {
        case .critical: String(localized: "Sweating")
        case .attention: mood.holdsSign ? String(localized: "Pointing at the suggested action") : String(localized: "Alert")
        case .good: mood.sleepy ? String(localized: "Dozing") : String(localized: "Relaxed")
        }
        setAccessibilityValue(value)
    }
}

/// One frame: body shape, eyes, hands and extras, in grid cells.
struct SlimePose: Equatable {
    enum Eyes: Equatable { case open, happy, closed, squint, dizzy, wide }
    enum Hand: Equatable {
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
    /// Body color.
    var tint: StatusLevel = .good
    /// A sign with a right arrow held up in the right hand, poked this many cells to the right (nil = no sign).
    var sign: Int?

    static func make(mood: SlimeMascot.Mood, frame f: Int, tappedAt: Int?) -> SlimePose {
        var p = SlimePose()
        // Breathing: a slow squash and stretch.
        let phase = f % 16
        let squash = phase < 4 ? 0 : phase < 6 ? 1 : phase < 12 ? 0 : phase < 14 ? -1 : 0
        p.halfWidth = 10 + squash
        p.height = 11 - squash
        let blinking = f % 36 < 2

        // A tap wins over everything for 1.5 s: a happy double jump with both hands up.
        if let t = tappedAt, f - t >= 0, f - t < 12 {
            let k = (f - t) % 6
            let jumps = [0, 2, 3, 3, 2, 0]
            p.jump = jumps[k]
            p.halfWidth = k == 0 ? 11 : 9
            p.height = k == 0 ? 10 : 12
            p.eyes = .happy
            p.tint = mood.level
            p.left = .up(2, lift: 0)
            p.right = .up(2, lift: 0)
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
                // Every 10 s: a wave with the right hand, happy eyes.
                let cycle = f % 80
                if cycle >= 56, !mood.holdsSign {
                    let k = cycle - 56
                    p.right = .up(min(2, k + 1, 80 - cycle), lift: (k / 2) % 2)
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

    enum Cell { case body, hand, outline, eye, white, sweat, snore, stick, board, boardEdge, arrow }

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
