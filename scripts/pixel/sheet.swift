// Contact sheet for reviewing pixel art: swift sheet.swift out.png scale bg(light|dark) a.png b.png …
import AppKit
let args = CommandLine.arguments
let out = args[1], scale = Int(args[2])!, dark = args[3] == "dark"
let images = args.dropFirst(4).compactMap { p -> (String, CGImage)? in
    guard let i = NSImage(contentsOfFile: p)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return (((p as NSString).lastPathComponent as NSString).deletingPathExtension, i)
}
let cell = (images.map { max($0.1.width, $0.1.height) }.max() ?? 16) * scale + 24
let cols = min(images.count, 6), rows = (images.count + cols - 1) / cols
let ctx = CGContext(data: nil, width: cols * cell, height: rows * cell + 0, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(dark ? CGColor(gray: 0.13, alpha: 1) : CGColor(gray: 0.95, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: cols * cell, height: rows * cell))
ctx.interpolationQuality = .none
for (i, (_, img)) in images.enumerated() {
    let x = (i % cols) * cell + 12, y = (rows - 1 - i / cols) * cell + 12
    ctx.draw(img, in: CGRect(x: x, y: y, width: img.width * scale, height: img.height * scale))
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
