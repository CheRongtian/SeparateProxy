import Darwin
import Foundation

public enum ChromeInfrastructure {
    public static let secureDNSHostname = "one.one.one.one"
    public static let secureDNSTemplates = """
    {
       "servers": [ {
          "endpoints": [ {
             "ips": [ "1.1.1.1", "1.0.0.1" ]
          } ],
          "template": "https://one.one.one.one/dns-query{?dns}"
       } ]
    }
    """
}

public enum ProxyWebsiteHostnameError: LocalizedError, Equatable {
    case emptyInput
    case internalWhitespace
    case invalidURL
    case unsupportedScheme
    case credentialsNotAllowed
    case unsupportedPort
    case invalidHostname
    case multipleTrailingDots
    case ipLiteralNotAllowed
    case tooManyHostnames
    case notNormalized

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Enter an HTTPS website or hostname."
        case .internalWhitespace:
            return "Website addresses cannot contain whitespace."
        case .invalidURL:
            return "The website address is invalid."
        case .unsupportedScheme:
            return "Only HTTPS website addresses are supported."
        case .credentialsNotAllowed:
            return "Website addresses cannot contain a username or password."
        case .unsupportedPort:
            return "Only the default HTTPS port 443 is supported."
        case .invalidHostname:
            return "The website hostname is invalid."
        case .multipleTrailingDots:
            return "A hostname can contain at most one trailing dot."
        case .ipLiteralNotAllowed:
            return "IP address literals are not supported."
        case .tooManyHostnames:
            return "Proxy Websites supports at most 100 hostnames."
        case .notNormalized:
            return "The helper received a website hostname that was not normalized."
        }
    }
}

public enum ProxyWebsiteHostnameNormalizer {
    public static let maximumHostnameCount = 100

    public static func normalize(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProxyWebsiteHostnameError.emptyInput
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw ProxyWebsiteHostnameError.internalWhitespace
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme else {
            throw ProxyWebsiteHostnameError.invalidURL
        }
        guard scheme.lowercased() == "https" else {
            throw ProxyWebsiteHostnameError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw ProxyWebsiteHostnameError.credentialsNotAllowed
        }
        guard let authorityStart = candidate.range(of: "://")?.upperBound else {
            throw ProxyWebsiteHostnameError.invalidURL
        }
        let authority = candidate[authorityStart...]
            .prefix { !"/?#".contains($0) }
        guard !authority.hasSuffix(":") else {
            throw ProxyWebsiteHostnameError.unsupportedPort
        }
        if let port = components.port, port != 443 {
            throw ProxyWebsiteHostnameError.unsupportedPort
        }
        guard var hostname = components.url?.host?.lowercased(), !hostname.isEmpty else {
            throw ProxyWebsiteHostnameError.invalidHostname
        }

        if hostname.hasSuffix("..") {
            throw ProxyWebsiteHostnameError.multipleTrailingDots
        }
        if hostname.hasSuffix(".") {
            hostname.removeLast()
        }

        guard !isIPAddress(hostname) else {
            throw ProxyWebsiteHostnameError.ipLiteralNotAllowed
        }
        try validateDNSHostname(hostname)
        return hostname
    }

    public static func validateNormalizedList(_ hostnames: [String]) throws -> [String] {
        guard hostnames.count <= maximumHostnameCount else {
            throw ProxyWebsiteHostnameError.tooManyHostnames
        }

        var normalized = Set<String>()
        for hostname in hostnames {
            guard hostname == hostname.trimmingCharacters(in: .whitespacesAndNewlines),
                  hostname == hostname.lowercased(),
                  !hostname.contains("://"),
                  !hostname.contains("/"),
                  !hostname.contains("?"),
                  !hostname.contains("#"),
                  !hostname.contains("*"),
                  try normalize(hostname) == hostname else {
                throw ProxyWebsiteHostnameError.notNormalized
            }
            normalized.insert(hostname)
        }
        guard normalized.count <= maximumHostnameCount else {
            throw ProxyWebsiteHostnameError.tooManyHostnames
        }
        return normalized.sorted()
    }

    public static func adding(_ input: String, to hostnames: [String]) throws -> [String] {
        let hostname = try normalize(input)
        var result = try validateNormalizedList(hostnames)
        if !result.contains(hostname) {
            guard result.count < maximumHostnameCount else {
                throw ProxyWebsiteHostnameError.tooManyHostnames
            }
            result.append(hostname)
            result.sort()
        }
        return result
    }

    private static func validateDNSHostname(_ hostname: String) throws {
        guard hostname.utf8.count <= 253,
              hostname.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw ProxyWebsiteHostnameError.invalidHostname
        }

        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else {
            throw ProxyWebsiteHostnameError.invalidHostname
        }
        for label in labels {
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first != "-",
                  label.last != "-",
                  label.unicodeScalars.allSatisfy({ scalar in
                      (scalar.value >= 48 && scalar.value <= 57)
                          || (scalar.value >= 97 && scalar.value <= 122)
                          || scalar.value == 45
                  }) else {
                throw ProxyWebsiteHostnameError.invalidHostname
            }
        }
    }

    private static func isIPAddress(_ hostname: String) -> Bool {
        var ipv4 = in_addr()
        if hostname.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return hostname.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
    }
}
