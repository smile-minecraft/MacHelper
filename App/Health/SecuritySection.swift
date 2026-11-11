import AppKit
import Diagnostics
import SwiftUI

/// Read-only macOS security settings: what each one is, whether it is on, and where to change it.
struct SecuritySection: View {
    let model: HealthModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Security Settings").font(.mhHeadline).foregroundStyle(Palette.text)
                if let checks = model.security {
                    let weak = checks.filter { $0.state == .off || $0.state == .partial }.count
                    Text(weak == 0 ? String(localized: "All on") : String(localized: "\(weak) could be safer"))
                        .font(.mhCallout).foregroundStyle(weak == 0 ? Palette.textMuted : Theme.amber)
                }
                Spacer()
                if model.checkingSecurity, model.security != nil {
                    ProgressView().controlSize(.small).help("Checking again…")
                }
                IconButton(symbol: "arrow.clockwise", help: "Check Again") { Task { await model.loadSecurity(forceRefresh: true) } }
                    .disabled(model.checkingSecurity)
            }
            if let checks = model.security {
                VStack(spacing: 0) {
                    ForEach(Array(checks.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                        SecurityRow(check: c)
                    }
                }
                .card(padding: 0)
                Text("Buttons open the matching page in System Settings.")
                    .font(.mhCaption).foregroundStyle(Palette.textFaint)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

private struct SecurityRow: View {
    let check: SecurityCheck

    var body: some View {
        let text = SecurityText(check)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).font(.mhTitle3).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(text.title).font(.mhBody.weight(.medium)).foregroundStyle(Palette.text)
                    Text(text.state).font(.mhCallout).foregroundStyle(check.state == .off || check.state == .partial ? Theme.amber : Palette.textMuted)
                }
                Text(text.detail).font(.mhCallout).foregroundStyle(Palette.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let url = text.settings, check.state == .off || check.state == .partial {
                Button("Open Settings") { NSWorkspace.shared.open(url) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch check.state {
        case .on: "checkmark.shield"
        case .off: "exclamationmark.shield"
        case .partial: "shield.lefthalf.filled"
        case .info: "info.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch check.state {
        case .off, .partial: Theme.amber
        case .unknown: Palette.textFaint
        case .on, .info: Palette.textMuted
        }
    }
}

/// The words for one check: its name, its state and what it means for the user.
private struct SecurityText {
    let title: String
    let state: String
    let detail: String
    let settings: URL?

    init(_ c: SecurityCheck) {
        let privacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?General")
        let unknown = String(localized: "Couldn’t be read")
        switch c.id {
        case "gatekeeper":
            title = String(localized: "Gatekeeper")
            settings = privacy
            (state, detail) = switch c.state {
            case .on: (String(localized: "On"), String(localized: "Apps from unknown developers need your approval before they open the first time."))
            case .off: (String(localized: "Off"), String(localized: "Any downloaded app opens without a check. Turn it back on unless you need it off for a specific app."))
            default: (unknown, String(localized: "Checks downloaded apps before they open."))
            }
        case "filevault":
            title = String(localized: "FileVault disk encryption")
            settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault")
            (state, detail) = switch c.state {
            case .on: (String(localized: "On"), String(localized: "The startup disk is encrypted. Without your password nobody can read it, even with the disk removed."))
            case .off: (String(localized: "Off"), String(localized: "The startup disk isn’t encrypted: anyone who gets this Mac can read its files. Encrypting runs in the background while you keep working."))
            case .partial: (String(localized: "In progress"), String(localized: "The disk is being encrypted or decrypted right now."))
            default: (unknown, String(localized: "Encrypts the startup disk."))
            }
        case "firewall":
            title = String(localized: "Firewall")
            settings = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")
            (state, detail) = switch c.state {
            case .on: (String(localized: "On"), c.detail == "stealth"
                       ? String(localized: "Incoming connections are filtered, and this Mac doesn’t answer probes from the network (stealth mode).")
                       : String(localized: "Incoming connections to apps are filtered."))
            case .off: (String(localized: "Off"), String(localized: "Apps can accept connections from the network without asking. Worth turning on if you use public Wi-Fi."))
            default: (unknown, String(localized: "Filters incoming network connections."))
            }
        case "sip":
            title = String(localized: "System Integrity Protection")
            settings = nil
            (state, detail) = switch c.state {
            case .on: (String(localized: "On"), String(localized: "System files can’t be changed, not even by an administrator or malware with your password."))
            case .off: (String(localized: "Off"), String(localized: "System files can be changed. It can only be turned back on from macOS Recovery (csrutil enable)."))
            case .partial: (String(localized: "Partly on"), String(localized: "Some protections were turned off in macOS Recovery. They can only be restored there (csrutil enable)."))
            default: (unknown, String(localized: "Protects system files from changes."))
            }
        case "updates":
            title = String(localized: "Automatic security updates")
            settings = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
            (state, detail) = switch c.state {
            case .on: (String(localized: "On"), String(localized: "Security responses and malware definitions install by themselves."))
            case .off: (String(localized: "Off"), String(localized: "Security fixes and malware definitions don’t install by themselves. In Software Update → Automatic Updates, turn on “Install Security Responses and system files”."))
            case .partial: (String(localized: "Partly on"), String(localized: "Only some security updates install by themselves. In Software Update → Automatic Updates, turn on “Install Security Responses and system files”."))
            default: (unknown, String(localized: "Installs security fixes by themselves."))
            }
        default:
            title = String(localized: "XProtect malware definitions")
            settings = nil
            let parts = (c.detail ?? "").split(separator: " ").map(String.init)
            switch (c.state, parts.count) {
            case (.info, 2...):
                state = String(localized: "Version \(parts[0])")
                detail = String(localized: "macOS’s built-in malware scanner. Definitions installed \(parts[1]).")
            case (.info, 1):
                state = String(localized: "Version \(parts[0])")
                detail = String(localized: "macOS’s built-in malware scanner.")
            default:
                state = unknown
                detail = String(localized: "macOS’s built-in malware scanner.")
            }
        }
    }
}
