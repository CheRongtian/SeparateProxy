import Foundation
import Security

public enum SeparateProxyIdentifiers {
    public static let helper = "com.cherongtian.SeparateProxy.Helper"
    public static let helperPlist = "com.cherongtian.SeparateProxy.Helper.plist"
    private static let helperBundleSuffix = ".Helper"

    public static func helperBundleIdentifier(forAppIdentifier identifier: String) -> String {
        identifier + helperBundleSuffix
    }

    public static func appBundleIdentifier(forHelperIdentifier identifier: String) -> String? {
        guard identifier.hasSuffix(helperBundleSuffix) else {
            return nil
        }
        return String(identifier.dropLast(helperBundleSuffix.count))
    }
}

public enum ProxyState: String, Sendable {
    case helperNotInstalled
    case approvalRequired
    case stopped
    case starting
    case running
    case stopping
    case error
}

public enum HelperReplyKey {
    public static let success = "success"
    public static let state = "state"
    public static let message = "message"
}

public enum TrafficAccountingReplyKey {
    public static let success = "success"
    public static let message = "message"
    public static let sessionIdentifier = "sessionIdentifier"
    public static let proxyUploadBytes = "proxyUploadBytes"
    public static let proxyDownloadBytes = "proxyDownloadBytes"
    public static let directUploadBytes = "directUploadBytes"
    public static let directDownloadBytes = "directDownloadBytes"
}

@objc public protocol SeparateProxyHelperProtocol {
    func status(withReply reply: @escaping (NSDictionary) -> Void)

    func startProxy(
        accessKey: String,
        chromeBundlePath: String,
        codexEnabled: Bool,
        gitEnabled: Bool,
        dockerEnabled: Bool,
        vsCodeBundlePath: String,
        proxyWebsiteHostnames: [String],
        withReply reply: @escaping (NSDictionary) -> Void
    )

    func stopProxy(withReply reply: @escaping (NSDictionary) -> Void)

    func getTrafficCounters(withReply reply: @escaping (NSDictionary) -> Void)
}

public enum CodeSigningRequirementBuilder {
    public static func requirement(identifier: String, teamIdentifier: String) -> String? {
        let identifierPattern = #"^[A-Za-z0-9.-]+$"#
        let teamPattern = #"^[A-Z0-9]{10}$"#
        guard identifier.range(of: identifierPattern, options: .regularExpression) != nil,
              teamIdentifier.range(of: teamPattern, options: .regularExpression) != nil else {
            return nil
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

public struct CodeSigningIdentityInfo: Sendable {
    public let identifier: String
    public let teamIdentifier: String

    public init(identifier: String, teamIdentifier: String) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
    }
}

public enum CodeSigningIdentity {
    public static func current() -> CodeSigningIdentityInfo? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [String: Any],
        let identifier = information[kSecCodeInfoIdentifier as String] as? String,
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String else {
            return nil
        }
        return CodeSigningIdentityInfo(
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
    }
}
