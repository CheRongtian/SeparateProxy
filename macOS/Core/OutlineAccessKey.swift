import Foundation

public struct OutlineAccessKey: Equatable, Sendable {
    public let server: String
    public let serverPort: UInt16
    public let method: String
    public let password: String

    public init(server: String, serverPort: UInt16, method: String, password: String) {
        self.server = server
        self.serverPort = serverPort
        self.method = method
        self.password = password
    }
}

public enum OutlineAccessKeyError: LocalizedError, Equatable {
    case invalidScheme
    case emptyKey
    case invalidBase64
    case missingCredentials
    case emptyMethodOrPassword
    case missingEndpoint
    case invalidPort

    public var errorDescription: String? {
        switch self {
        case .invalidScheme:
            return "The Outline access key must use the ss:// scheme."
        case .emptyKey:
            return "The Outline access key is empty."
        case .invalidBase64:
            return "The Outline access key contains invalid Base64 data."
        case .missingCredentials:
            return "The Outline access key is missing method and password credentials."
        case .emptyMethodOrPassword:
            return "The Outline method or password is empty."
        case .missingEndpoint:
            return "The Outline access key is missing a server or port."
        case .invalidPort:
            return "The Outline server port is invalid."
        }
    }
}

public enum OutlineAccessKeyParser {
    public static func parse(_ rawValue: String) throws -> OutlineAccessKey {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("ss://") else {
            throw OutlineAccessKeyError.invalidScheme
        }

        var body = String(key.dropFirst(5))
        if let fragmentIndex = body.firstIndex(of: "#") {
            body = String(body[..<fragmentIndex])
        }
        if let queryIndex = body.firstIndex(of: "?") {
            body = String(body[..<queryIndex])
        }
        guard !body.isEmpty else {
            throw OutlineAccessKeyError.emptyKey
        }

        let credentialsPart: String
        let endpointPart: String

        if let separator = body.lastIndex(of: "@") {
            credentialsPart = String(body[..<separator])
            endpointPart = String(body[body.index(after: separator)...])
        } else {
            let decoded = try decodeBase64(body.removingPercentEncoding ?? body)
            guard let separator = decoded.lastIndex(of: "@") else {
                throw OutlineAccessKeyError.missingEndpoint
            }
            credentialsPart = String(decoded[..<separator])
            endpointPart = String(decoded[decoded.index(after: separator)...])
        }

        let credentials = try parseCredentials(credentialsPart)
        let endpoint = try parseEndpoint(endpointPart)
        return OutlineAccessKey(
            server: endpoint.server,
            serverPort: endpoint.port,
            method: credentials.method,
            password: credentials.password
        )
    }

    private static func parseCredentials(_ rawValue: String) throws -> (method: String, password: String) {
        let value = rawValue.removingPercentEncoding ?? rawValue
        let decoded = value.contains(":") ? value : try decodeBase64(value)
        guard let separator = decoded.firstIndex(of: ":") else {
            throw OutlineAccessKeyError.missingCredentials
        }
        let method = String(decoded[..<separator])
        let password = String(decoded[decoded.index(after: separator)...])
        guard !method.isEmpty, !password.isEmpty else {
            throw OutlineAccessKeyError.emptyMethodOrPassword
        }
        return (method, password)
    }

    private static func parseEndpoint(_ value: String) throws -> (server: String, port: UInt16) {
        guard let components = URLComponents(string: "ss://placeholder@\(value)"),
              let host = components.host,
              !host.isEmpty else {
            throw OutlineAccessKeyError.missingEndpoint
        }
        guard let portValue = components.port,
              let port = UInt16(exactly: portValue),
              port > 0 else {
            throw OutlineAccessKeyError.invalidPort
        }
        return (host, port)
    }

    private static func decodeBase64(_ rawValue: String) throws -> String {
        var value = rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value.append(String(repeating: "=", count: (4 - value.count % 4) % 4))
        guard let data = Data(base64Encoded: value),
              let decoded = String(data: data, encoding: .utf8) else {
            throw OutlineAccessKeyError.invalidBase64
        }
        return decoded
    }
}
