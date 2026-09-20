import Darwin
import Foundation

public struct DockerDesktopBackendInstallation: Equatable, Sendable {
    public let applicationBundlePath: String
    public let backendExecutablePath: String

    public init(
        applicationBundlePath: String,
        backendExecutablePath: String
    ) {
        self.applicationBundlePath = applicationBundlePath
        self.backendExecutablePath = backendExecutablePath
    }
}

public struct DockerHubInstallation: Equatable, Sendable {
    public let backendInstallation: DockerDesktopBackendInstallation
    public let cliExecutablePath: String

    public var applicationBundlePath: String {
        backendInstallation.applicationBundlePath
    }

    public var backendExecutablePath: String {
        backendInstallation.backendExecutablePath
    }

    public init(
        applicationBundlePath: String,
        backendExecutablePath: String,
        cliExecutablePath: String
    ) {
        backendInstallation = DockerDesktopBackendInstallation(
            applicationBundlePath: applicationBundlePath,
            backendExecutablePath: backendExecutablePath
        )
        self.cliExecutablePath = cliExecutablePath
    }

    public init(
        backendInstallation: DockerDesktopBackendInstallation,
        cliExecutablePath: String
    ) {
        self.backendInstallation = backendInstallation
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
            return "Docker Desktop support is unavailable: \(reason)"
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

public enum KubernetesRoutePolicy {
    public static let artifactRegistryLocations = [
        "northamerica-northeast1",
        "northamerica-northeast2",
        "northamerica-south1",
        "us-central1",
        "us-east1",
        "us-east4",
        "us-east5",
        "us-south1",
        "us-west1",
        "us-west2",
        "us-west3",
        "us-west4",
        "southamerica-east1",
        "southamerica-west1",
        "europe-central2",
        "europe-north1",
        "europe-north2",
        "europe-southwest1",
        "europe-west1",
        "europe-west2",
        "europe-west3",
        "europe-west4",
        "europe-west6",
        "europe-west8",
        "europe-west9",
        "europe-west10",
        "europe-west12",
        "me-central1",
        "me-central2",
        "me-west1",
        "asia-east1",
        "asia-east2",
        "asia-northeast1",
        "asia-northeast2",
        "asia-northeast3",
        "asia-south1",
        "asia-south2",
        "asia-southeast1",
        "asia-southeast2",
        "asia-southeast3",
        "australia-southeast1",
        "australia-southeast2",
        "africa-south1",
        "asia",
        "europe",
        "us",
    ]

    public static let artifactRegistryHostnames = artifactRegistryLocations.map {
        "\($0)-docker.pkg.dev"
    }

    public static let backendHostnames = [
        "registry.k8s.io",
        "cdn.registry.k8s.io",
    ] + artifactRegistryHostnames
}

public enum ContainerRegistriesRoutePolicy {
    public static let backendHostnames = [
        "gcr.io",
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

    public static func resolveBackendIfEnabled(
        _ enabled: Bool,
        discovery: () throws -> DockerDesktopBackendInstallation
    ) rethrows -> DockerDesktopBackendInstallation? {
        guard enabled else { return nil }
        return try discovery()
    }

    public func discoverBackendInstallation() throws -> DockerDesktopBackendInstallation {
        let (canonicalBundle, expectedOwner) = try discoverApplicationBundle()
        let backendExecutable = try validateNestedExecutable(
            relativePath: Self.backendExecutableRelativePath,
            expectedBasename: "com.docker.backend",
            label: "the Docker backend",
            bundle: canonicalBundle,
            expectedOwner: expectedOwner
        )
        return DockerDesktopBackendInstallation(
            applicationBundlePath: canonicalBundle.path,
            backendExecutablePath: backendExecutable.path
        )
    }

    public func discoverActiveInstallation() throws -> DockerHubInstallation {
        let (canonicalBundle, expectedOwner) = try discoverApplicationBundle()
        let backendExecutable = try validateNestedExecutable(
            relativePath: Self.backendExecutableRelativePath,
            expectedBasename: "com.docker.backend",
            label: "the Docker backend",
            bundle: canonicalBundle,
            expectedOwner: expectedOwner
        )
        let cliExecutable = try validateNestedExecutable(
            relativePath: Self.cliExecutableRelativePath,
            expectedBasename: "docker",
            label: "the bundled Docker CLI",
            bundle: canonicalBundle,
            expectedOwner: expectedOwner
        )

        return DockerHubInstallation(
            backendInstallation: DockerDesktopBackendInstallation(
                applicationBundlePath: canonicalBundle.path,
                backendExecutablePath: backendExecutable.path
            ),
            cliExecutablePath: cliExecutable.path
        )
    }

    private func discoverApplicationBundle() throws -> (URL, uid_t) {
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
        return (canonicalBundle, bundleInformation.st_uid)
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
