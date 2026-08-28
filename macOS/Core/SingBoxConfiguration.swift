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
            public let network: String?
            public let destinationPort: UInt16?
            public let action: String
            public let sniffer: [String]?
            public let overrideDestination: Bool?
            public let protocolName: String?
            public let domains: [String]?
            public let overrideAddress: String?
            public let method: String?
            public let noDrop: Bool?
            public let outbound: String?

            enum CodingKeys: String, CodingKey {
                case network, action, sniffer, method, outbound
                case processPathRegex = "process_path_regex"
                case ipVersion = "ip_version"
                case destinationPort = "port"
                case overrideDestination = "override_destination"
                case protocolName = "protocol"
                case domains = "domain"
                case overrideAddress = "override_address"
                case noDrop = "no_drop"
            }

            public init(
                processPathRegex: [String],
                ipVersion: Int? = nil,
                network: String? = nil,
                destinationPort: UInt16? = nil,
                action: String,
                sniffer: [String]? = nil,
                overrideDestination: Bool? = nil,
                protocolName: String? = nil,
                domains: [String]? = nil,
                overrideAddress: String? = nil,
                method: String? = nil,
                noDrop: Bool? = nil,
                outbound: String? = nil
            ) {
                self.processPathRegex = processPathRegex
                self.ipVersion = ipVersion
                self.network = network
                self.destinationPort = destinationPort
                self.action = action
                self.sniffer = sniffer
                self.overrideDestination = overrideDestination
                self.protocolName = protocolName
                self.domains = domains
                self.overrideAddress = overrideAddress
                self.method = method
                self.noDrop = noDrop
                self.outbound = outbound
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
    case invalidCodexExecutablePath
    case invalidVSCodePluginHelperExecutablePath
    case noTargetsSelected

    public var errorDescription: String? {
        switch self {
        case .invalidChromeBundlePath:
            return "The Google Chrome application path is invalid."
        case .invalidCodexExecutablePath:
            return "The Codex executable path is invalid."
        case .invalidVSCodePluginHelperExecutablePath:
            return "The Visual Studio Code Plugin Helper executable path is invalid."
        case .noTargetsSelected:
            return "Select at least one proxy target."
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

    public static func make(
        outline: OutlineAccessKey,
        chromeBundlePath: String?,
        codexExecutablePath: String?,
        vsCodePluginHelperExecutablePath: String?
    ) throws -> SingBoxConfiguration {
        guard chromeBundlePath != nil || codexExecutablePath != nil else {
            throw SingBoxConfigurationError.noTargetsSelected
        }
        guard (codexExecutablePath == nil) == (vsCodePluginHelperExecutablePath == nil) else {
            throw SingBoxConfigurationError.invalidVSCodePluginHelperExecutablePath
        }

        if let chromeBundlePath {
            let chromeConfiguration = try make(
                outline: outline,
                chromeBundlePath: chromeBundlePath
            )
            guard let codexExecutablePath else {
                return chromeConfiguration
            }
            let codexRules = try makeCodexRules(
                executablePath: codexExecutablePath,
                vsCodePluginHelperExecutablePath: vsCodePluginHelperExecutablePath!
            )
            return SingBoxConfiguration(
                log: chromeConfiguration.log,
                inbounds: chromeConfiguration.inbounds,
                outbounds: chromeConfiguration.outbounds,
                route: .init(
                    autoDetectInterface: chromeConfiguration.route.autoDetectInterface,
                    rules: chromeConfiguration.route.rules + codexRules,
                    final: chromeConfiguration.route.final
                )
            )
        }

        let codexRules = try makeCodexRules(
            executablePath: codexExecutablePath!,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperExecutablePath!
        )
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
                rules: codexRules,
                final: "direct"
            )
        )
    }

    private static func makeCodexRules(
        executablePath: String,
        vsCodePluginHelperExecutablePath: String
    ) throws -> [SingBoxConfiguration.Route.Rule] {
        guard executablePath.hasPrefix("/"),
              URL(fileURLWithPath: executablePath).lastPathComponent == "codex",
              !executablePath.contains("\n"),
              !executablePath.contains("\0") else {
            throw SingBoxConfigurationError.invalidCodexExecutablePath
        }

        let normalizedPath = URL(fileURLWithPath: executablePath)
            .standardizedFileURL.path
        let escapedPath = NSRegularExpression.escapedPattern(for: normalizedPath)
            .replacingOccurrences(of: #"\/"#, with: "/")
        let processPathRegex = ["^\(escapedPath)$"]
        guard vsCodePluginHelperExecutablePath.hasPrefix("/"),
              URL(fileURLWithPath: vsCodePluginHelperExecutablePath).lastPathComponent == "Code Helper (Plugin)",
              !vsCodePluginHelperExecutablePath.contains("\n"),
              !vsCodePluginHelperExecutablePath.contains("\0") else {
            throw SingBoxConfigurationError.invalidVSCodePluginHelperExecutablePath
        }
        let normalizedVSCodeHelperPath = URL(
            fileURLWithPath: vsCodePluginHelperExecutablePath
        ).standardizedFileURL.path
        let escapedVSCodeHelperPath = NSRegularExpression.escapedPattern(
            for: normalizedVSCodeHelperPath
        ).replacingOccurrences(of: #"\/"#, with: "/")
        let vsCodeHelperProcessPathRegex = ["^\(escapedVSCodeHelperPath)$"]
        return [
            .init(
                processPathRegex: processPathRegex,
                network: "tcp",
                destinationPort: 443,
                action: "sniff",
                sniffer: ["tls"],
                overrideDestination: true
            ),
            .init(
                processPathRegex: processPathRegex,
                action: "route",
                outbound: "outline"
            ),
            .init(
                processPathRegex: vsCodeHelperProcessPathRegex,
                network: "tcp",
                destinationPort: 443,
                action: "sniff",
                sniffer: ["tls"]
            ),
            .init(
                processPathRegex: vsCodeHelperProcessPathRegex,
                network: "tcp",
                destinationPort: 443,
                action: "route",
                protocolName: "tls",
                domains: ["chatgpt.com"],
                overrideAddress: "chatgpt.com",
                outbound: "outline"
            ),
        ]
    }
}
