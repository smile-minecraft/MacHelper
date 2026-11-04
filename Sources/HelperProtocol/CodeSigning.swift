import Foundation
import Security

/// Code-signing introspection used to pin the XPC peer on both sides.
///
/// Two modes, chosen automatically from how the binaries are signed:
/// - **Team ID** (Developer ID / Apple Development): `anchor apple generic` + team + identifier.
///   Survives rebuilds and updates.
/// - **Ad-hoc** (no Apple account): identifier + exact cdhash of the peer binary.
///   An ad-hoc signature has no certificate chain, so the hash is the only thing an attacker
///   cannot forge. The hash changes on every build, which is fine because app and helper
///   always ship inside the same bundle.
public enum CodeSigning {
    public struct Info: Sendable, Equatable {
        public let identifier: String?
        public let teamID: String?
        public let cdhash: String?
        public var isAdHoc: Bool { teamID == nil }
    }

    public static func info(at url: URL) -> Info? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return info(of: code)
    }

    public static func currentProcess() -> Info? {
        var dynamic: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
              SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess, let code
        else { return nil }
        return info(of: code)
    }

    /// Requirement string a peer must satisfy. `expected` is read from the peer binary on disk
    /// at a location we trust (inside our own bundle).
    public static func requirement(identifier: String, expected: Info?) -> String? {
        if let team = expected?.teamID {
            return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        }
        if let hash = expected?.cdhash {
            return "identifier \"\(identifier)\" and cdhash H\"\(hash)\""
        }
        return nil
    }

    private static func info(of code: SecStaticCode) -> Info? {
        var dict: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dict) == errSecSuccess,
              let info = dict as? [String: Any]
        else { return nil }
        let hash = (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        return Info(
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            cdhash: hash
        )
    }
}
