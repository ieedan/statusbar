import Foundation

/// A compact relative age like "just now", "5m ago", "2h ago", "3d ago",
/// "2w ago". `now` is injectable for testing.
public func relativeAge(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    let days = hours / 24
    if days < 7 { return "\(days)d ago" }
    return "\(days / 7)w ago"
}
