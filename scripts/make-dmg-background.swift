#!/usr/bin/env swift
//
// Renders the installer window background: a light gray field with a dashed arrow
// pointing from the app to the Applications shortcut.
//
//   swift scripts/make-dmg-background.swift <output.tiff>
//
// Writes a 540×380 image with a 2× representation so it stays sharp on Retina
// displays (`tiffutil -cathidpicheck` joins the two). The committed result lives at
// assets/dmg-background.tiff; re-run this after changing the design. Keep the
// window size and arrow position in step with scripts/dmg-settings.py.
//
import AppKit

let size = CGSize(width: 540, height: 380)
// Where the app and Applications icons sit (see dmg-settings.py); the arrow goes between.
// Finder measures icon positions from the top, drawing here is from the bottom.
let arrowCenter = CGPoint(x: 270, y: size.height - 220)

func render(scale: Int) -> Data {
    let pixelsWide = Int(size.width) * scale
    let pixelsHigh = Int(size.height) * scale
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    // Tag the density so the 1× and 2× images are recognised as one picture.
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    NSColor(srgbRed: 0.925, green: 0.925, blue: 0.925, alpha: 1).setFill()
    CGRect(origin: .zero, size: size).fill()

    // A block arrow pointing right.
    let bodyHalfHeight: CGFloat = 11.5
    let headHalfHeight: CGFloat = 30
    let left: CGFloat = arrowCenter.x - 25
    let neck: CGFloat = arrowCenter.x - 5
    let tip: CGFloat = arrowCenter.x + 25
    let y = arrowCenter.y
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: left, y: y + bodyHalfHeight))
    arrow.line(to: CGPoint(x: neck, y: y + bodyHalfHeight))
    arrow.line(to: CGPoint(x: neck, y: y + headHalfHeight))
    arrow.line(to: CGPoint(x: tip, y: y))
    arrow.line(to: CGPoint(x: neck, y: y - headHalfHeight))
    arrow.line(to: CGPoint(x: neck, y: y - bodyHalfHeight))
    arrow.line(to: CGPoint(x: left, y: y - bodyHalfHeight))
    arrow.close()
    arrow.lineWidth = 1.5
    arrow.lineJoinStyle = .miter
    arrow.setLineDash([3, 2.5], count: 2, phase: 0)
    NSColor(srgbRed: 0.33, green: 0.33, blue: 0.33, alpha: 1).setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <output.tiff>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
    "StatusBar-dmg-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let oneX = tmp.appendingPathComponent("bg.png")
let twoX = tmp.appendingPathComponent("bg@2x.png")
try render(scale: 1).write(to: oneX)
try render(scale: 2).write(to: twoX)

try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
task.arguments = ["-cathidpicheck", oneX.path, twoX.path, "-out", output.path]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
