import Foundation

public struct SingBoxConfiguration: Codable, Equatable, Sendable {
    public struct Log: Codable, Equatable, Sendable {
        public let level: String
        public let timestamp: Bool
    }

    public struct Inbound: Codable, Equatable, Sendable {
        public let type: String
        public let tag: String
        public let address: [String]
        public let autoRoute: Bool
        public let stack: String

        enum CodingKeys: String, CodingKey {
            case type, tag, address, stack
            case autoRoute = "auto_route"
        }
    }

    public struct Outbound: Codable, Equatable, Sendable {
        public let type: String
        public let tag: String
        public let server: String?
        public let serverPort: UInt16?
        public let method: String?
        public let password: String?

        enum CodingKeys: String, CodingKey {
            case type, tag, server, method, password
            case serverPort = "server_port"
        }
    }

    public struct Route: Codable, Equatable, Sendable {
        public struct Rule: Codable, Equatable, Sendable {
            public let processPathRegex: [String]
            public let ipVersion: Int?
            public let action: String
            public let method: String?
            public let noDrop: Bool?
            public let outbound: String?

            enum CodingKeys: String, CodingKey {
                case action, method, outbound
                case processPathRegex = "process_path_regex"
                case ipVersion = "ip_version"
                case noDrop = "no_drop"
            }
        }

        public let autoDetectInterface: Bool
        public let rules: [Rule]
        public let final: String

        enum CodingKeys: String, CodingKey {
            case rules, final
            case autoDetectInterface = "auto_detect_interface"
        }
    }

    public let log: Log
    public let inbounds: [Inbound]
    public let outbounds: [Outbound]
    public let route: Route

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum SingBoxConfigurationError: LocalizedError, Equatable {
    case invalidChromeBundlePath

    public var errorDescription: String? {
        switch self {
        case .invalidChromeBundlePath:
            return "The Google Chrome application path is invalid."
        }
    }
}

public enum SingBoxConfigurationBuilder {
    public static func make(
        outline: OutlineAccessKey,
        chromeBundlePath: String
    ) throws -> SingBoxConfiguration {
        guard chromeBundlePath.hasPrefix("/"),
              chromeBundlePath.hasSuffix(".app"),
              !chromeBundlePath.contains("\n"),
              !chromeBundlePath.contains("\0") else {
            throw SingBoxConfigurationError.invalidChromeBundlePath
        }

        let normalizedPath = URL(fileURLWithPath: chromeBundlePath)
            .standardizedFileURL.path
        let escapedPath = NSRegularExpression.escapedPattern(for: normalizedPath)
            .replacingOccurrences(of: #"\/"#, with: "/")
        let chromeRegex = "^\(escapedPath)/"

        return SingBoxConfiguration(
            log: .init(level: "info", timestamp: true),
            inbounds: [
                .init(
                    type: "tun",
                    tag: "tun-in",
                    address: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                    autoRoute: true,
                    stack: "system"
                )
            ],
            outbounds: [
                .init(
                    type: "direct",
                    tag: "direct",
                    server: nil,
                    serverPort: nil,
                    method: nil,
                    password: nil
                ),
                .init(
                    type: "shadowsocks",
                    tag: "outline",
                    server: outline.server,
                    serverPort: outline.serverPort,
                    method: outline.method,
                    password: outline.password
                )
            ],
            route: .init(
                autoDetectInterface: true,
                rules: [
                    .init(
                        processPathRegex: [chromeRegex],
                        ipVersion: 6,
                        action: "reject",
                        method: "default",
                        noDrop: true,
                        outbound: nil
                    ),
                    .init(
                        processPathRegex: [chromeRegex],
                        ipVersion: nil,
                        action: "route",
                        method: nil,
                        noDrop: nil,
                        outbound: "outline"
                    )
                ],
                final: "direct"
            )
        )
    }
}
