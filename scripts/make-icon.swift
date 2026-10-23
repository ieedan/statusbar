#!/usr/bin/env swift
//
// Renders the StatusBar app icon: the three status shapes (circle = operational,
// rounded square = major, triangle = minor) overlapped along a diagonal on one tile.
//
//   swift scripts/make-icon.swift <output.icns>
//   ICON_STYLE=filled swift scripts/make-icon.swift <output.icns>    (default: outline)
//   ICON_PALETTE=navy swift scripts/make-icon.swift <output.icns>    (default: light)
//   ICON_ANGLE=45 swift scripts/make-icon.swift <output.icns>        (default: 30)
//
// Draws every size an .icns needs, then runs `iconutil`. The committed result
// lives at assets/AppIcon.icns; re-run this after changing the design.
//
import AppKit

let canvas: CGFloat = 1024

// Palette — the same hues the menubar uses (see StatusIcons.swift).
let red = NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)
let orange = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)

func hex(_ value: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

struct Palette {
    let tileTop: NSColor
    let tileBottom: NSColor
    let ring: NSColor
    let rim: NSColor
}

let palettes: [String: Palette] = [
    "light": Palette(tileTop: hex(0xFFFFFF), tileBottom: hex(0xE3E6EE), ring: hex(0x6B7280), rim: NSColor.black.withAlphaComponent(0.10)),
    "navy": Palette(tileTop: hex(0x22397A), tileBottom: hex(0x0B1535), ring: hex(0x7FB4FF), rim: NSColor.white.withAlphaComponent(0.14)),
]
let palette = palettes[ProcessInfo.processInfo.environment["ICON_PALETTE"] ?? "light"]!
let tileTop = palette.tileTop
let tileBottom = palette.tileBottom

func roundedSquare(center c: CGPoint, side: CGFloat) -> NSBezierPath {
    let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
    return NSBezierPath(roundedRect: rect, xRadius: side * 0.28, yRadius: side * 0.28)
}

func triangle(center c: CGPoint, width: CGFloat) -> NSBezierPath {
    // Equilateral, centered on its centroid so it sits optically in the middle.
    let h = width * sqrt(3) / 2
    let path = NSBezierPath()
    path.move(to: CGPoint(x: c.x, y: c.y + h * 2 / 3))
    path.line(to: CGPoint(x: c.x + width / 2, y: c.y - h / 3))
    path.line(to: CGPoint(x: c.x - width / 2, y: c.y - h / 3))
    path.close()
    path.lineJoinStyle = .round
    return path
}

func circle(center c: CGPoint, diameter: CGFloat) -> NSBezierPath {
    NSBezierPath(
        ovalIn: CGRect(
            x: c.x - diameter / 2, y: c.y - diameter / 2, width: diameter, height: diameter))
}

/// Cuts a gap of `gap` on each side of `path`'s outline out of whatever is already
/// drawn, so shapes underneath read as passing *behind* it instead of mixing with it.
/// `interior` clears the inside too, which makes an outlined shape opaque.
func knockOut(_ path: NSBezierPath, width: CGFloat, gap: CGFloat, interior: Bool) {
    guard let cg = NSGraphicsContext.current?.cgContext else { return }
    path.lineJoinStyle = .round
    path.lineWidth = width + gap * 2
    cg.setBlendMode(.clear)
    if interior { path.fill() }
    path.stroke()
    cg.setBlendMode(.normal)
}

func drawIcon(into ctx: CGContext) {
    let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = nsctx

    // macOS icon grid: an 824pt tile centered on the 1024pt canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -14), blur: 28,
        color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    tilePath.fill()
    ctx.restoreGState()

    // Everything else is clipped to the tile so the knock-outs can't eat the shadow.
    ctx.saveGState()
    tilePath.addClip()
    NSGradient(starting: tileTop, ending: tileBottom)?.draw(in: tile, angle: -90)

    // The shapes are drawn into a transparent layer so the gaps can be cut out
    // of it, then that layer is composited over the tile.
    let layer = CGLayer(ctx, size: CGSize(width: canvas, height: canvas), auxiliaryInfo: nil)!
    let lctx = layer.context!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: lctx, flipped: false)

    let c = CGPoint(x: canvas / 2, y: canvas / 2 - 4)
    func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: c.x + dx, y: c.y + dy) }

    // Three shapes overlapping along one diagonal, high-left to low-right: circle
    // (operational), triangle (minor), square (major). Their bounding-box centers sit
    // on a single straight axis at equal spacing, so the steps are even. Each shape
    // after the first cuts a gap around itself so the overlaps stay crisp.
    let env = ProcessInfo.processInfo.environment
    let outlined = (env["ICON_STYLE"] ?? "outline") == "outline"
    let degrees = Double(env["ICON_ANGLE"] ?? "") ?? 30
    let width: CGFloat = outlined ? 44 : 14  // stroke: the outline itself, or just corner softening
    let gap: CGFloat = outlined ? 18 : 20
    let scale: CGFloat = outlined ? 0.94 : 1
    let sizes: (circle: CGFloat, square: CGFloat, triangle: CGFloat) =
        outlined ? (290 * scale, 270 * scale, 330 * scale) : (320 * scale, 300 * scale, 360 * scale)
    let spacing: CGFloat = (outlined ? 205 : 215) * scale
    let step = CGPoint(
        x: spacing * CGFloat(cos(degrees * .pi / 180)),
        y: -spacing * CGFloat(sin(degrees * .pi / 180)))
    // The centroid sits below the bounding-box middle; lift it so the triangle's box is centered.
    let triY = -(sizes.triangle * sqrt(3) / 2) / 6
    let circlePath = circle(center: at(-step.x, -step.y), diameter: sizes.circle)
    // Pushes the square a little further along the axis so only the triangle's corner tucks under it.
    let reach: CGFloat = outlined ? 1.2 : 1
    let squarePath = roundedSquare(center: at(step.x * reach, step.y * reach), side: sizes.square)
    let trianglePath = triangle(center: at(0, triY), width: sizes.triangle)

    // `opaque` shapes hide whatever is behind them (an outline would otherwise let it
    // show through the open middle).
    var stack: [(NSBezierPath, NSColor, opaque: Bool)]
    if outlined {
        // Circle ← triangle ← square: the triangle slips under the square at the end.
        stack = [
            (circlePath, palette.ring, false),
            (trianglePath, orange, true),
            (squarePath, red, true),
        ]
    } else {
        // Solid shapes can't weave, so the triangle stays in front where it reads whole.
        stack = [
            (circlePath, palette.ring, false),
            (squarePath, red, false),
            (trianglePath, orange, false),
        ]
    }
    for (i, (path, color, opaque)) in stack.enumerated() {
        if i > 0 { knockOut(path, width: width, gap: gap, interior: opaque || !outlined) }
        path.lineJoinStyle = .round
        path.lineWidth = width
        color.setStroke()
        if !outlined {
            color.setFill()
            path.fill()
        }
        path.stroke()
    }

    NSGraphicsContext.current = nsctx
    ctx.draw(layer, at: .zero)

    // Fine top-edge highlight, like system icons have.
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
    rim.lineWidth = 3
    palette.rim.setStroke()
    rim.stroke()
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    ctx.interpolationQuality = .high
    drawIcon(into: ctx)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - main

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("StatusBar-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// (point size, scale) pairs an .iconset expects.
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: size * scale).write(to: iconset.appendingPathComponent(name))
    }
}

try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
