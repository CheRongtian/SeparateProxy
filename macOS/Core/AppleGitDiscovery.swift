import Darwin
import Foundation

public struct AppleGitInstallation: Equatable, Sendable {
    public let developerDirectoryPath: String
    public let gitExecutablePath: String
    public let httpsHelperEntryPath: String
    public let canonicalHTTPHelperPath: String

    public init(
        developerDirectoryPath: String,
        gitExecutablePath: String,
        httpsHelperEntryPath: String,
        canonicalHTTPHelperPath: String
    ) {
        self.developerDirectoryPath = developerDirectoryPath
        self.gitExecutablePath = gitExecutablePath
        self.httpsHelperEntryPath = httpsHelperEntryPath
        self.canonicalHTTPHelperPath = canonicalHTTPHelperPath
    }
}

public enum AppleGitDiscoveryError: LocalizedError, Equatable {
    case notInstalled
    case invalidInstallation(String)
    case developerDirectoryUnavailable

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Apple/Xcode Git is not installed in the active developer directory."
        case let .invalidInstallation(reason):
            return "The Git HTTPS helper could not be validated: \(reason)"
        case .developerDirectoryUnavailable:
            return "The active Apple developer directory could not be determined."
        }
    }
}

public struct AppleGitDiscovery {
    public static let gitExecutableRelativePath = "usr/bin/git"
    public static let httpsHelperRelativePath = "usr/libexec/git-core/git-remote-https"
    public static let httpHelperRelativePath = "usr/libexec/git-core/git-remote-http"

    private let expectedOwner: uid_t
    private let fileManager: FileManager
    private let activeDeveloperDirectory: () throws -> String

    public init(
        expectedOwner: uid_t = 0,
        fileManager: FileManager = .default,
        activeDeveloperDirectory: (() throws -> String)? = nil
    ) {
        self.expectedOwner = expectedOwner
        self.fileManager = fileManager
        self.activeDeveloperDirectory = activeDeveloperDirectory ?? {
            try XcodeSelectDeveloperDirectory.activePath()
        }
    }

    public static func resolveIfEnabled(
        _ enabled: Bool,
        discovery: () throws -> AppleGitInstallation
    ) rethrows -> AppleGitInstallation? {
        guard enabled else { return nil }
        return try discovery()
    }

    public func discoverActiveInstallation() throws -> AppleGitInstallation {
        let developerPath: String
        do {
            developerPath = try activeDeveloperDirectory()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw AppleGitDiscoveryError.developerDirectoryUnavailable
        }
        guard developerPath.hasPrefix("/"), !developerPath.isEmpty else {
            throw AppleGitDiscoveryError.developerDirectoryUnavailable
        }

        let developerDirectory = try canonicalDirectory(
            URL(fileURLWithPath: developerPath, isDirectory: true)
        )
        let gitExecutable = developerDirectory.appendingPathComponent(
            Self.gitExecutableRelativePath
        )
        let httpsHelperEntry = developerDirectory.appendingPathComponent(
            Self.httpsHelperRelativePath
        )
        let expectedHTTPHelper = developerDirectory.appendingPathComponent(
            Self.httpHelperRelativePath
        )

        try requireContained(gitExecutable, in: developerDirectory)
        try requireContained(httpsHelperEntry, in: developerDirectory)
        try requireContained(expectedHTTPHelper, in: developerDirectory)
        try validateRegularExecutable(gitExecutable, label: "the Git executable")
        try validateHTTPSHelperEntry(
            httpsHelperEntry,
            expectedHTTPHelper: expectedHTTPHelper,
            developerDirectory: developerDirectory
        )
        try validateRegularExecutable(
            expectedHTTPHelper,
            label: "the canonical HTTP helper"
        )

        let canonicalEntry = httpsHelperEntry
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let canonicalHTTPHelper = expectedHTTPHelper
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard canonicalEntry == canonicalHTTPHelper else {
            throw AppleGitDiscoveryError.invalidInstallation(
                "git-remote-https does not resolve to the expected git-remote-http sibling"
            )
        }
        try requireContained(canonicalHTTPHelper, in: developerDirectory)

        return AppleGitInstallation(
            developerDirectoryPath: developerDirectory.path,
            gitExecutablePath: gitExecutable.path,
            httpsHelperEntryPath: httpsHelperEntry.path,
            canonicalHTTPHelperPath: canonicalHTTPHelper.path
        )
    }

    private func canonicalDirectory(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var information = stat()
        guard lstat(resolved.path, &information) == 0 else {
            throw AppleGitDiscoveryError.notInstalled
        }
        guard information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == expectedOwner else {
            throw AppleGitDiscoveryError.invalidInstallation(
                "the active developer directory has an unexpected owner or type"
            )
        }
        return resolved
    }

    private func validateRegularExecutable(_ url: URL, label: String) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw AppleGitDiscoveryError.notInstalled
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == expectedOwner else {
            throw AppleGitDiscoveryError.invalidInstallation(
                "\(label) has an unexpected owner or file type"
            )
        }
        guard information.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else {
            throw AppleGitDiscoveryError.invalidInstallation(
                "\(label) is not executable"
            )
        }
    }

    private func validateHTTPSHelperEntry(
        _ entry: URL,
        expectedHTTPHelper: URL,
        developerDirectory: URL
    ) throws {
        var information = stat()
        guard lstat(entry.path, &information) == 0 else {
            throw AppleGitDiscoveryError.notInstalled
        }
        guard information.st_mode & S_IFMT == S_IFLNK,
              information.st_uid == expectedOwner else {
            throw AppleGitDiscoveryError.invalidInstallation(
                "git-remote-https is not the expected owned symbolic link"
            )
        }

        let target: String
        do {
            target = try fileManager.destinationOfSymbolicLink(atPath: entry.path)
        } catch {
            throw AppleGitDiscoveryError.invalidInstallation(
                "git-remote-https has an unreadable symbolic-link target"
            )
        }
        guard target == expectedHTTPHelper.lastPathComponent else {
            throw AppleGitDiscoveryError.invalidInstallation(
                "git-remote-https has an unexpected symbolic-link target"
            )
        }
        try requireContained(entry, in: developerDirectory)
    }

    private func requireContained(_ candidate: URL, in parent: URL) throws {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        guard candidateComponents.count > parentComponents.count,
              Array(candidateComponents.prefix(parentComponents.count)) == parentComponents else {
            throw AppleGitDiscoveryError.invalidInstallation(
                "a required Git path escapes the active developer directory"
            )
        }
    }
}

private enum XcodeSelectDeveloperDirectory {
    static func activePath() throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            throw AppleGitDiscoveryError.developerDirectoryUnavailable
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppleGitDiscoveryError.developerDirectoryUnavailable
        }
        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8), !path.isEmpty else {
            throw AppleGitDiscoveryError.developerDirectoryUnavailable
        }
        return path
    }
}
