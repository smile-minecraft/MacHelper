import AppKit
import ServiceManagement

/// Every System Settings page MacHelper can send someone to, in one place.
///
/// The rest of the app names a page and never builds a `x-apple.systempreferences` URL itself, so a
/// changed identifier has one home. Login Items has no URL: macOS only opens it through
/// `SMAppService`, and doing so is also what the approval flow expects.
enum SystemSettingsPane: String, CaseIterable, Sendable {
    /// Privacy & Security → Full Disk Access.
    case fullDiskAccess
    /// Privacy & Security → Accessibility (macOS 27 renames the list, not the page).
    case accessibility
    /// Privacy & Security → Automation.
    case automation
    /// Notifications.
    case notifications
    /// General → Login Items & Extensions, including the background agents and the Finder extension.
    case loginItems
    /// Privacy & Security → General (Gatekeeper).
    case privacySecurityGeneral
    /// Privacy & Security → FileVault.
    case fileVault
    /// Network → Firewall.
    case firewall
    /// General → Software Update.
    case softwareUpdate

    /// The deep link, or nil for the one page macOS opens through its own API.
    var url: URL? {
        switch self {
        case .fullDiskAccess:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .automation:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        case .loginItems:
            // SMAppService owns this page; there is no documented URL for it.
            nil
        case .privacySecurityGeneral:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?General")
        case .fileVault:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault")
        case .firewall:
            URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")
        case .softwareUpdate:
            URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
        }
    }

    /// Opens the page. Login Items goes through `SMAppService`, the only supported way in.
    @MainActor
    func open() {
        if self == .loginItems {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
