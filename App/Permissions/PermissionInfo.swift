import Foundation
import Permissions

/// How a permission is granted, so a screen can pick the right instruction and the right button.
enum PermissionGrantMethod: String, CaseIterable, Sendable {
    /// Flip MacHelper's switch in the list.
    case systemToggle
    /// macOS does not list MacHelper before the first grant; it has to be added with the + button.
    case addAppManually
    /// Ask macOS and it shows its own permission alert.
    case systemPrompt
    /// Approve the entry in Login Items & Extensions.
    case loginItemsApproval
}

/// The fixed copy for one permission, written once here instead of in each screen.
///
/// Every sentence is checked against the code: `purpose` names the features that call the API,
/// `withoutIt` what they lose, and `neverAccessed` what the permission is never used for. A
/// permission without a concrete difference would not be in this list.
struct PermissionInfo: Identifiable, Equatable, Sendable {
    let id: PermissionID
    let title: String
    /// The app features that need this permission.
    let purpose: String
    /// What stops working when it is not granted.
    let withoutIt: String
    /// The data this permission is never used to read or send.
    let neverAccessed: String
    let grantMethod: PermissionGrantMethod
    let settingsPane: SystemSettingsPane

    static func info(for id: PermissionID) -> PermissionInfo {
        switch id {
        case .helper:
            PermissionInfo(
                id: id,
                title: String(localized: "MacHelper Helper"),
                purpose: String(localized: "Fan speeds, Deep Clean of system caches, logs and diagnostic reports, maintenance tasks, the full process list, system launch daemons, and moving system-wide leftovers to the Trash."),
                withoutIt: String(localized: "MacHelper can still measure and clean your own caches, but it can’t change fan speeds, clean system folders, read other users’ process counters, change launch daemons or move system-wide leftovers."),
                neverAccessed: String(localized: "The Helper deletes only the folders in its allowlist, and only when you ask. It reads CPU and memory counters, background item records and launch daemon settings — never your documents — and sends nothing off this Mac."),
                grantMethod: .loginItemsApproval,
                settingsPane: .loginItems)
        case .fullDiskAccess:
            PermissionInfo(
                id: id,
                title: String(localized: "Full Disk Access"),
                purpose: String(localized: "Measuring and cleaning the folders macOS protects: Mail downloads, Safari and browser caches, other apps’ containers, and the folders Disk Analysis can’t read without it."),
                withoutIt: String(localized: "Disk Analysis and Optimize skip protected folders: their space is missing from the numbers and their caches can’t be cleaned."),
                neverAccessed: String(localized: "MacHelper measures folders by name, size and date, and reads an app bundle’s metadata to recognise it. File contents are read only on this Mac, when you look for duplicate files or preview one. No file names, paths or contents are sent anywhere. There is no camera, microphone or screen recording access."),
                grantMethod: .addAppManually,
                settingsPane: .fullDiskAccess)
        case .accessibility:
            PermissionInfo(
                id: id,
                title: String(localized: "Accessibility"),
                purpose: String(localized: "The keyboard and mouse tweaks: cut and paste in Finder, Dock click actions, window buttons, ⌘Tab restore, quit guard, the window menu and Mission Control buttons."),
                withoutIt: String(localized: "Those tweaks stay inactive. Everything else in MacHelper works the same."),
                neverAccessed: String(localized: "Key presses and clicks only decide whether the event is passed on; they are never stored or sent. Window titles are read for the window menu and the Mission Control overlay."),
                grantMethod: .systemPrompt,
                settingsPane: .accessibility)
        case .finderAutomation:
            PermissionInfo(
                id: id,
                title: String(localized: "Finder automation"),
                purpose: String(localized: "New File in Finder asks Finder which folder its front window shows, so the new file lands in the folder you are looking at."),
                withoutIt: String(localized: "The New File shortcut can’t tell which folder is open and does nothing."),
                neverAccessed: String(localized: "Only the folder path of Finder’s front window is requested. MacHelper doesn’t read Finder’s files and doesn’t control other apps."),
                grantMethod: .systemPrompt,
                settingsPane: .automation)
        case .finderExtension:
            PermissionInfo(
                id: id,
                title: String(localized: "Finder extension"),
                purpose: String(localized: "The MacHelper items in Finder’s context menu: New File, Copy Path, Open in Terminal and Cut."),
                withoutIt: String(localized: "Finder’s context menu has no MacHelper items. The menu bar window list and every other tweak keep working."),
                neverAccessed: String(localized: "The extension adds menu items and hands the request to MacHelper. It has no file access of its own."),
                grantMethod: .systemToggle,
                settingsPane: .loginItems)
        case .notifications:
            PermissionInfo(
                id: id,
                title: String(localized: "Notifications"),
                purpose: String(localized: "The Monitor alerts you turn on (temperature, memory pressure, low disk space) and the warnings when the Helper stops."),
                withoutIt: String(localized: "Alerts stay inside MacHelper’s window. Nothing appears when a threshold is crossed or the Helper stops."),
                neverAccessed: String(localized: "A notification carries only the reading that crossed its threshold or the Helper state; no file names, paths or contents."),
                grantMethod: .systemPrompt,
                settingsPane: .notifications)
        case .backgroundRecording:
            PermissionInfo(
                id: id,
                title: String(localized: "Background recording"),
                purpose: String(localized: "Recording Monitor history while MacHelper is closed, so the charts have no gaps after you quit."),
                withoutIt: String(localized: "History is recorded only while MacHelper runs; the time after you quit is missing."),
                neverAccessed: String(localized: "The local database holds readings and process names, without paths or command lines. Nothing leaves this Mac."),
                grantMethod: .loginItemsApproval,
                settingsPane: .loginItems)
        case .autoCleanSchedule:
            PermissionInfo(
                id: id,
                title: String(localized: "Auto Clean"),
                purpose: String(localized: "Running the scheduled low-risk clean while MacHelper is closed: caches, logs and developer build caches."),
                withoutIt: String(localized: "Cleaning happens only when you run it yourself."),
                neverAccessed: String(localized: "Only low-risk caches and logs are deleted; documents, photos and downloads are never touched. Every deletion is listed in the operation log."),
                grantMethod: .loginItemsApproval,
                settingsPane: .loginItems)
        case .openAtLogin:
            PermissionInfo(
                id: id,
                title: String(localized: "Open at login"),
                purpose: String(localized: "Starting MacHelper when you log in, so the menu bar item and its readings are there."),
                withoutIt: String(localized: "You open MacHelper yourself after logging in."),
                neverAccessed: String(localized: "It only starts the app. It doesn’t register background services or start recording."),
                grantMethod: .systemToggle,
                settingsPane: .loginItems)
        }
    }

    /// Every permission in declaration order. Screens should order by state instead; this is the
    /// complete set, with no entry that the app does not use.
    static let all: [PermissionInfo] = PermissionID.allCases.map(info(for:))
}

extension PermissionState {
    /// Default wording for a status badge. A screen may shorten it, but the strings live here so
    /// every caller describes the same state with the same words.
    var label: String {
        switch self {
        case .granted: String(localized: "On")
        case .needsApproval: String(localized: "Needs approval")
        case .denied: String(localized: "Denied")
        case .notRequested: String(localized: "Not granted")
        case .notApplicable: String(localized: "Not needed")
        case .checking: String(localized: "Checking…")
        }
    }
}
