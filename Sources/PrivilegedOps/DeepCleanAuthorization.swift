import Foundation
import Security

/// The administrator password check in front of deep clean.
///
/// The app makes an empty authorization reference in the user's login session and passes its
/// external form along with the request. The root Helper turns it back into a reference and asks
/// for MacHelper's own right with interaction allowed, so macOS shows the password (or Touch ID)
/// dialog in the user's session. The right is defined by the Helper as an administrator check that
/// root cannot skip (`authenticate-admin-nonshared`: `allow-root` false, not shared with other
/// apps), so the Helper running as root does not satisfy it by itself.
public enum DeepCleanAuthorization {
    public static let rightName = "com.machelper.MacHelper.deep-clean"
    /// Built-in rule: an administrator name and password, not shared, valid 30 s, root not exempt.
    static let ruleName = "authenticate-admin-nonshared"

    static var definition: [String: Any] {
        [
            "class": "rule",
            "rule": ruleName,
            "version": 1,
            "comment": "Deletes system caches, rotated logs and temporary files with MacHelper's Deep Clean.",
            "default-prompt": [
                "": "MacHelper wants to run Deep Clean. It deletes old system caches, logs and temporary files as administrator.",
                "zh_TW": "MacHelper 要執行深層優化，會以管理員身分刪除舊的系統快取、日誌與暫存檔。",
                "zh_CN": "MacHelper 要执行深层优化，会以管理员身份删除旧的系统缓存、日志与临时文件。",
                "ja": "MacHelper がディープクリーンを実行しようとしています。古いシステムキャッシュ、ログ、一時ファイルを管理者として削除します。",
                "ko": "MacHelper가 심층 정리를 실행하려고 합니다. 오래된 시스템 캐시, 로그 및 임시 파일을 관리자로 삭제합니다.",
                "es": "MacHelper quiere ejecutar la limpieza profunda. Borra cachés, registros y archivos temporales antiguos del sistema como administrador.",
            ],
        ]
    }

    /// Whether a stored definition is the one this right must have. Anyone may add a right that
    /// doesn't exist yet, so a definition planted before the Helper's (say, `allow`) must be replaced.
    static func isExpected(_ stored: [String: Any]) -> Bool {
        guard stored["class"] as? String == "rule" else { return false }
        if let rule = stored["rule"] as? String { return rule == ruleName }
        if let rules = stored["rule"] as? [String] { return rules == [ruleName] }
        return false
    }

    // MARK: App side

    /// An authorization reference held by the app for one deep clean. Its rights are destroyed
    /// when it is released, so a granted password never outlives the request.
    public final class Session: @unchecked Sendable {
        private let ref: AuthorizationRef
        /// `AuthorizationExternalForm` bytes to send to the Helper.
        public let externalForm: Data

        public init() throws {
            var ref: AuthorizationRef?
            var status = AuthorizationCreate(nil, nil, [], &ref)
            guard status == errAuthorizationSuccess, let ref else { throw SystemCleanupError.authorizationDenied(status) }
            var form = AuthorizationExternalForm()
            status = AuthorizationMakeExternalForm(ref, &form)
            guard status == errAuthorizationSuccess else {
                AuthorizationFree(ref, [])
                throw SystemCleanupError.authorizationDenied(status)
            }
            self.ref = ref
            externalForm = withUnsafeBytes(of: &form) { Data($0) }
        }

        deinit { AuthorizationFree(ref, [.destroyRights]) }
    }

    // MARK: Helper side

    /// Shows the administrator dialog in the session that made `externalForm` and returns once the
    /// user authenticated. Throws for a malformed form, a cancelled dialog or a refusal.
    public static func authorize(_ externalForm: Data?) throws {
        guard let externalForm, externalForm.count == MemoryLayout<AuthorizationExternalForm>.size else {
            throw SystemCleanupError.authorizationRequired
        }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { externalForm.copyBytes(to: $0) }
        var ref: AuthorizationRef?
        var status = AuthorizationCreateFromExternalForm(&form, &ref)
        guard status == errAuthorizationSuccess, let ref else { throw SystemCleanupError.authorizationDenied(status) }
        defer { AuthorizationFree(ref, []) }

        try installRight()

        status = rightName.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { items in
                var rights = AuthorizationRights(count: 1, items: items)
                return AuthorizationCopyRights(ref, &rights, nil, [.extendRights, .interactionAllowed], nil)
            }
        }
        switch status {
        case errAuthorizationSuccess: return
        case errAuthorizationCanceled: throw SystemCleanupError.authorizationCancelled
        default: throw SystemCleanupError.authorizationDenied(status)
        }
    }

    /// Defines (or repairs) the right in the authorization database. Runs as root, which may add and
    /// modify rights without asking.
    static func installRight() throws {
        var stored: CFDictionary?
        if AuthorizationRightGet(rightName, &stored) == errAuthorizationSuccess,
           let dict = stored as? [String: Any], isExpected(dict) {
            return
        }
        var ref: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &ref)
        guard status == errAuthorizationSuccess, let ref else { throw SystemCleanupError.authorizationDenied(status) }
        defer { AuthorizationFree(ref, []) }
        status = AuthorizationRightSet(ref, rightName, definition as CFDictionary, nil, nil, nil)
        guard status == errAuthorizationSuccess else { throw SystemCleanupError.authorizationDenied(status) }
    }
}
