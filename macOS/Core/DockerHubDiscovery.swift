import Darwin
import Foundation

public struct DockerHubInstallation: Equatable, Sendable {
    public let applicationBundlePath: String
    public let backendExecutablePath: String
    public let cliExecutablePath: String

    public init(
        applicationBundlePath: String,
        backendExecutablePath: String,
        cliExecutablePath: String
    ) {
        self.applicationBundlePath = applicationBundlePath
        self.backendExecutablePath = backendExecutablePath
        self.cliExecutablePath = cliExecutablePath
    }
}

public enum DockerHubDiscoveryError: LocalizedError, Equatable {
    case notInstalled
    case invalidInstallation(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Docker Desktop was not found."
        case let .invalidInstallation(reason):
            return "Docker Hub support is unavailable: \(reason)"
        }
    }
}

public enum DockerHubRoutePolicy {
    public static let backendHostnames = [
        "registry-1.docker.io",
        "auth.docker.io",
        "production.cloudfront.docker.com",
        "login.docker.com",
        "hub.docker.com",
        "api.docker.com",
    ]

    public static let cliHostnames = [
        "login.docker.com",
        "hub.docker.com",
    ]
}

public struct DockerHubDiscovery {
    public static let applicationBundleIdentifier = "com.docker.docker"
    public static let backendExecutableRelativePath = "Contents/MacOS/com.docker.backend"
    public static let cliExecutableRelativePath = "Contents/Resources/bin/docker"

    private let fileManager: FileManager
    private let applicationURLProvider: () -> URL?

    public init(
        fileManager: FileManager = .default,
        applicationURLProvider: @escaping () -> URL?
    ) {
        self.fileManager = fileManager
        self.applicationURLProvider = applicationURLProvider
    }

    public static func resolveIfEnabled(
        _ enabled: Bool,
        discovery: () throws -> DockerHubInstallation
    ) rethrows -> DockerHubInstallation? {
        guard enabled else { return nil }
        return try discovery()
    }

    public func discoverActiveInstallation() throws -> DockerHubInstallation {
        guard let candidate = applicationURLProvider() else {
            throw DockerHubDiscoveryError.notInstalled
        }
        guard candidate.isFileURL else {
            throw DockerHubDiscoveryError.invalidInstallation(
                "the application location is not a local file URL"
            )
        }

        let canonicalBundle = candidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var bundleInformation = stat()
        guard canonicalBundle.pathExtension == "app",
              lstat(canonicalBundle.path, &bundleInformation) == 0 else {
            throw DockerHubDiscoveryError.notInstalled
        }
        guard bundleInformation.st_mode & S_IFMT == S_IFDIR else {
            throw DockerHubDiscoveryError.invalidInstallation(
                "the application bundle is not a directory"
            )
        }
        guard let bundle = Bundle(url: canonicalBundle),
              bundle.bundleIdentifier == Self.applicationBundleIdentifier else {
            throw DockerHubDiscoveryError.invalidInstallation(
                "the bundle identifier is not \(Self.applicationBundleIdentifier)"
            )
        }

        let backendExecutable = try validateNestedExecutable(
            relativePath: Self.backendExecutableRelativePath,
            expectedBasename: "com.docker.backend",
            label: "the Docker backend",
            bundle: canonicalBundle,
            expectedOwner: bundleInformation.st_uid
        )
        let cliExecutable = try validateNestedExecutable(
            relativePath: Self.cliExecutableRelativePath,
            expectedBasename: "docker",
            label: "the bundled Docker CLI",
            bundle: canonicalBundle,
            expectedOwner: bundleInformation.st_uid
        )

        return DockerHubInstallation(
            applicationBundlePath: canonicalBundle.path,
            backendExecutablePath: backendExecutable.path,
            cliExecutablePath: cliExecutable.path
        )
    }

    private func validateNestedExecutable(
        relativePath: String,
        expectedBasename: String,
        label: String,
        bundle: URL,
        expectedOwner: uid_t
    ) throws -> URL {
        let entry = bundle
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard entry.lastPathComponent == expectedBasename,
              isStrictDescendant(entry, of: bundle) else {
            throw DockerHubDiscoveryError.invalidInstallation(
                "\(label) has an invalid fixed path"
            )
        }

        var information = stat()
        guard lstat(entry.path, &information) == 0 else {
            throw DockerHubDiscoveryError.invalidInstallation(
                "\(label) is missing"
            )
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw DockerHubDiscoveryError.invalidInstallation(
                "\(label) is not a regular non-symlink file"
            )
        }
        guard information.st_uid == expectedOwner else {
            throw DockerHubDiscoveryError.invalidInstallation(
                "\(label) has an unexpected owner"
            )
        }
        guard information.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0,
              fileManager.isExecutableFile(atPath: entry.path) else {
            throw DockerHubDiscoveryError.invalidInstallation(
                "\(label) is not executable"
            )
        }

        let canonicalEntry = entry
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard canonicalEntry == entry,
              isStrictDescendant(canonicalEntry, of: bundle) else {
            throw DockerHubDiscoveryError.invalidInstallation(
                "\(label) resolves outside the validated application bundle"
            )
        }
        return canonicalEntry
    }

    private func isStrictDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        return candidateComponents.count > parentComponents.count
            && Array(candidateComponents.prefix(parentComponents.count)) == parentComponents
    }
}
