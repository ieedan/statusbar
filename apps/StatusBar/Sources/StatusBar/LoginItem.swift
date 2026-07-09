import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` — the modern (macOS 13+) way for an
/// app to register *itself* as a login item, no helper bundle or LaunchAgent
/// plist required. The registration points at whatever bundle is currently
/// running, so the app should live in a stable location (e.g. /Applications).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "requires approval in System Settings › Login Items"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    /// Registers or unregisters the app as a login item. Returns the resulting
    /// enabled state. Throws if the system rejects the change.
    @discardableResult
    static func setEnabled(_ enabled: Bool) throws -> Bool {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else {
            if service.status == .enabled { try service.unregister() }
        }
        return service.status == .enabled
    }
}
