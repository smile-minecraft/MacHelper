import FanControl
import Foundation

/// The app-side fan preferences: automatic switching, the base policy, and the saved custom curve.
///
/// Speeds travel as fractions of a fan's own min…max range, so the same values are meaningful on a
/// Mac with different fan limits. Only a Mac without controllable fans is incompatible. Applying a
/// policy still goes through the existing helper path, which validates and enforces its own limits.
public struct FanSettingsPayload: Codable, Equatable, Sendable {
    public var autoEnabled: Bool
    public var autoRules: [FanAutoRule]
    public var basePolicy: FanPolicy
    /// Points saved by the curve editor; present only after the user edited a curve.
    public var customCurve: [FanCurve.Point]?

    public init(autoEnabled: Bool = false,
                autoRules: [FanAutoRule] = [],
                basePolicy: FanPolicy = .automatic,
                customCurve: [FanCurve.Point]? = nil) {
        self.autoEnabled = autoEnabled
        self.autoRules = autoRules
        self.basePolicy = basePolicy
        self.customCurve = customCurve
    }

    /// Decodes and validates with the same limits the fan UI and the helper use. `hasFans` comes
    /// from the app's hardware probe; this module never reads SMC itself.
    public static func validated(_ data: Data, hasFans: Bool) -> SectionValidation {
        let incoming: FanSettingsPayload
        do {
            incoming = try JSONDecoder().decode(FanSettingsPayload.self, from: data)
        } catch {
            return .invalid(String(describing: error))
        }
        // Content errors come first: a payload no Mac can use is invalid, not merely incompatible.
        do {
            _ = try incoming.basePolicy.validated()
            for point in incoming.customCurve ?? [] {
                guard point.celsius.isFinite, point.fraction.isFinite,
                      (20...110).contains(point.celsius), (0...1).contains(point.fraction)
                else { return .invalid("curve point out of range") }
            }
        } catch {
            return .invalid(String(describing: error))
        }
        guard hasFans else { return .incompatible("This Mac has no controllable fans.") }
        let bytes: Data
        do { bytes = try CanonicalJSON.encode(incoming) }
        catch { return .invalid(String(describing: error)) }
        return .valid(SettingsPayload(data: bytes, summary: "\(incoming.autoRules.count) automatic rules"))
    }
}
