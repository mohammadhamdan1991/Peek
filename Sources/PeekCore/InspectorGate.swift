#if !PEEK_DISABLED
import Foundation

/// Runtime lockout (layer 3). Fails closed: every check must prove the build is not production.
public enum InspectorGate {
    public struct Facts: Sendable {
        public var bundleIdentifier: String?
        /// Exact bundle ids allowed to run the inspector, e.g. `com.example.app.staging`. Nil allows any.
        public var allowedBundleIdentifiers: Set<String>?
        /// The host's own answer to "is this production?".
        public var isProductionEnvironment: Bool
        public var isAppStoreInstall: Bool

        public init(bundleIdentifier: String?, allowedBundleIdentifiers: Set<String>?, isProductionEnvironment: Bool, isAppStoreInstall: Bool) {
            self.bundleIdentifier = bundleIdentifier
            self.allowedBundleIdentifiers = allowedBundleIdentifiers
            self.isProductionEnvironment = isProductionEnvironment
            self.isAppStoreInstall = isAppStoreInstall
        }
    }

    public enum Decision: Sendable, Equatable {
        case allowed
        case denied(Reason)
    }

    public enum Reason: Sendable, Equatable {
        case productionEnvironment
        case bundleNotAllowed
        case appStoreInstall
    }

    public static func evaluate(_ facts: Facts) -> Decision {
        if facts.isProductionEnvironment { return .denied(.productionEnvironment) }
        if let allowed = facts.allowedBundleIdentifiers {
            guard let bundle = facts.bundleIdentifier, allowed.contains(bundle) else { return .denied(.bundleNotAllowed) }
        }
        if facts.isAppStoreInstall { return .denied(.appStoreInstall) }
        return .allowed
    }
}
#endif
