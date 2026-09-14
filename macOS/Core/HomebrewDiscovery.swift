import Darwin
import Foundation

public struct HomebrewInstallation: Equatable, Sendable {
    public let prefixPath: String
    public let brewExecutablePath: String
    public let libraryPath: String

    public init(
        prefixPath: String,
        brewExecutablePath: String,
        libraryPath: String
    ) {
        self.prefixPath = prefixPath
        self.brewExecutablePath = brewExecutablePath
        self.libraryPath = libraryPath
    }
}

public enum HomebrewDiscoveryError: LocalizedError, Equatable {
    case notInstalled
    case invalidInstallation(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Homebrew was not found in the default installation prefix."
        case let .invalidInstallation(reason):
            return "Homebrew support is unavailable: \(reason)"
        }
    }
}

enum HomebrewHostArchitecture {
    case appleSilicon
    case intel
}

public enum HomebrewRoutePolicy {
    public static let systemCurlExecutablePath = "/usr/bin/curl"
    public static let curlHostnames = [
        "formulae.brew.sh",
        "ghcr.io",
        "pkg-containers.githubusercontent.com",
        "api.github.com",
    ]
    public static let gitHostname = "github.com"
}

public struct HomebrewDiscovery {
    public static let appleSiliconDefaultPrefix = "/opt/homebrew"
    public static let intelDefaultPrefix = "/usr/local"

    private let prefixURL: URL
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
#if arch(arm64)
        let prefixPath = Self.defaultPrefixPath(for: .appleSilicon)
#else
        let prefixPath = Self.defaultPrefixPath(for: .intel)
#endif
        prefixURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
        self.fileManager = fileManager
    }

    init(prefixURL: URL, fileManager: FileManager = .default) {
        self.prefixURL = prefixURL
        self.fileManager = fileManager
    }

    static func defaultPrefixPath(for architecture: HomebrewHostArchitecture) -> String {
        switch architecture {
        case .appleSilicon:
            return appleSiliconDefaultPrefix
        case .intel:
            return intelDefaultPrefix
        }
    }

    public static func resolveIfEnabled(
        _ enabled: Bool,
        discovery: () throws -> HomebrewInstallation
    ) rethrows -> HomebrewInstallation? {
        guard enabled else { return nil }
        return try discovery()
    }

    public func discoverDefaultInstallation() throws -> HomebrewInstallation {
        guard prefixURL.isFileURL, prefixURL.path.hasPrefix("/") else {
            throw HomebrewDiscoveryError.invalidInstallation(
                "the default prefix is not an absolute local path"
            )
        }

        let prefix = prefixURL.standardizedFileURL
        let brewExecutable = prefix.appendingPathComponent("bin/brew")
        let library = prefix.appendingPathComponent("Library/Homebrew", isDirectory: true)

        try requireDirectory(prefix, missingIsNotInstalled: true, label: "the default prefix")
        try requireExecutableFile(brewExecutable)
        try requireDirectory(library, missingIsNotInstalled: true, label: "Library/Homebrew")

        return HomebrewInstallation(
            prefixPath: prefix.path,
            brewExecutablePath: brewExecutable.path,
            libraryPath: library.path
        )
    }

    private func requireDirectory(
        _ url: URL,
        missingIsNotInstalled: Bool,
        label: String
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            if missingIsNotInstalled {
                throw HomebrewDiscoveryError.notInstalled
            }
            throw HomebrewDiscoveryError.invalidInstallation("\(label) is missing")
        }
        guard isDirectory.boolValue else {
            throw HomebrewDiscoveryError.invalidInstallation("\(label) is not a directory")
        }
    }

    private func requireExecutableFile(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw HomebrewDiscoveryError.notInstalled
        }
        guard !isDirectory.boolValue else {
            throw HomebrewDiscoveryError.invalidInstallation("bin/brew is not a file")
        }
        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw HomebrewDiscoveryError.invalidInstallation("bin/brew is not executable")
        }
    }
}

public enum HomebrewSystemCurlValidator {
    public static func validate() throws -> String {
        let path = HomebrewRoutePolicy.systemCurlExecutablePath
        var information = stat()
        guard lstat(path, &information) == 0 else {
            throw HomebrewDiscoveryError.invalidInstallation(
                "the fixed system curl executable is missing"
            )
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == 0,
              information.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else {
            throw HomebrewDiscoveryError.invalidInstallation(
                "the fixed system curl path has an unexpected owner, type, or mode"
            )
        }

        let canonicalPath = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard canonicalPath == path else {
            throw HomebrewDiscoveryError.invalidInstallation(
                "the fixed system curl path does not preserve its canonical identity"
            )
        }
        return path
    }
}
