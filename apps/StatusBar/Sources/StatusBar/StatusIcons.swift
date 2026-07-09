import AppKit
import StatusCore

/// Color + shape mapping for status levels. Each severity gets a distinct
/// *shape* as well as a color, so the state is legible without relying on color
/// alone (accessibility, and easier to read at a glance in the menubar):
///
///   operational → circle · minor → triangle · major → rounded square
///   unknown     → dashed circle
enum StatusIcons {
    static func color(for level: StatusLevel) -> NSColor {
        switch level {
        case .major:       return .systemRed
        case .minor:       return .systemOrange
        case .operational: return .systemGray
        case .unknown:     return .tertiaryLabelColor
        }
    }

    /// Short human label for a level, used in the menubar summary row.
    static func label(for level: StatusLevel) -> String {
        switch level {
        case .major:       return "Major Outage"
        case .minor:       return "Minor Issues"
        case .operational: return "All Systems Operational"
        case .unknown:     return "Status Unknown"
        }
    }

    /// The shape image for a level. `filled` draws a solid glyph (used in the
    /// menubar for visibility); otherwise it's a stroked outline (used in the
    /// menu, matching the design).
    static func shape(for level: StatusLevel, filled: Bool = false, size: CGFloat = 13) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = Self.path(for: level, in: rect.insetBy(dx: 1.5, dy: 1.5))
            let color = Self.color(for: level)

            if level == .unknown {
                // Always a dashed outline — "no signal" reads as tentative.
                path.lineWidth = 1.4
                path.setLineDash([2, 1.6], count: 2, phase: 0)
                color.setStroke()
                path.stroke()
            } else if filled {
                color.setFill()
                path.fill()
            } else {
                path.lineWidth = 2
                color.setStroke()
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Shape paths

    private static func path(for level: StatusLevel, in rect: NSRect) -> NSBezierPath {
        switch level {
        case .operational, .unknown: return circle(in: rect)
        case .minor:                 return triangle(in: rect)
        case .major:                 return roundedSquare(in: rect)
        }
    }

    private static func circle(in rect: NSRect) -> NSBezierPath {
        NSBezierPath(ovalIn: rect)
    }

    private static func roundedSquare(in rect: NSRect) -> NSBezierPath {
        let radius = rect.width * 0.28
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    /// An upward-pointing triangle with slightly rounded joins, inset so its
    /// stroke sits inside `rect`.
    private static func triangle(in rect: NSRect) -> NSBezierPath {
        let r = rect.insetBy(dx: 0, dy: rect.height * 0.04)
        let top = NSPoint(x: r.midX, y: r.maxY)
        let left = NSPoint(x: r.minX, y: r.minY)
        let right = NSPoint(x: r.maxX, y: r.minY)
        let path = NSBezierPath()
        path.move(to: top)
        path.line(to: right)
        path.line(to: left)
        path.close()
        path.lineJoinStyle = .round
        return path
    }
}
