import Darwin
import Foundation

public enum AntigravityBackendState: Equatable, Sendable {
    case installed
    case pendingDownload
}

public struct AntigravityInstallation: Equatable, Sendable {
    public let version: String
    public let extensionRootPath: String
    public let agyExecutablePath: String
    public let backendState: AntigravityBackendState

    public init(
        version: String,
        extensionRootPath: String,
        agyExecutablePath: String,
        backendState: AntigravityBackendState
    ) {
        self.version = version
        self.extensionRootPath = extensionRootPath
        self.agyExecutablePath = agyExecutablePath
        self.backendState = backendState
    }
}

public enum AntigravityExtensionDiscoveryError: LocalizedError, Equatable {
    case notInstalled
    case incompleteInstallation(String)
    case unsupportedInstallation(String)
    case consoleUserUnavailable

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The Google Antigravity VS Code extension is not installed."
        case let .incompleteInstallation(reason):
            return "The Google Antigravity VS Code extension installation is incomplete: \(reason)"
        case let .unsupportedInstallation(reason):
            return "The Google Antigravity VS Code extension installation is unsupported: \(reason)"
        case .consoleUserUnavailable:
            return "The current console user is unavailable."
        }
    }
}

public enum AntigravityRouting {
    public static let serviceHostnames = [
        "accounts.google.com",
        "oauth2.googleapis.com",
        "www.googleapis.com",
        "lh3.googleusercontent.com",
        "antigravity.google",
        "cloudcode-pa.googleapis.com",
        "daily-cloudcode-pa.googleapis.com",
        "aicode.googleapis.com",
        "aiplatform.googleapis.com",
    ]

    public static let extensionHostDownloadHostnames = [
        "antigravity-cli-auto-updater-974169037036.us-central1.run.app",
        "storage.googleapis.com",
        "edgedl.me.gvt1.com",
    ]
}

public struct AntigravityExtensionDiscovery {
    public static let extensionIdentifier = "google.google-antigravity"
    public static let publisher = "google"
    public static let extensionName = "google-antigravity"
    public static let agyRelativePath = ".gemini/bin/agy"

    private static let machO64Magic: UInt32 = 0xfeedfacf
    private static let arm64CPUType: UInt32 = 0x0100000c

    private let homeDirectory: URL
    private let expectedOwner: uid_t
    private let fileManager: FileManager

    public init(
        homeDirectory: URL,
        expectedOwner: uid_t,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.expectedOwner = expectedOwner
        self.fileManager = fileManager
    }

    public static func forConsoleUser(
        fileManager: FileManager = .default
    ) throws -> AntigravityExtensionDiscovery {
        var consoleInformation = stat()
        guard lstat("/dev/console", &consoleInformation) == 0,
              consoleInformation.st_uid > 0,
              let record = getpwuid(consoleInformation.st_uid),
              let home = record.pointee.pw_dir else {
            throw AntigravityExtensionDiscoveryError.consoleUserUnavailable
        }

        return AntigravityExtensionDiscovery(
            homeDirectory: URL(
                fileURLWithPath: String(cString: home),
                isDirectory: true
            ),
            expectedOwner: consoleInformation.st_uid,
            fileManager: fileManager
        )
    }

    public static func resolveIfEnabled(
        _ enabled: Bool,
        discovery: () throws -> AntigravityInstallation
    ) rethrows -> AntigravityInstallation? {
        guard enabled else { return nil }
        return try discovery()
    }

    public func discoverActiveInstallation() throws -> AntigravityInstallation {
        let extensionsDirectory = homeDirectory
            .appendingPathComponent(".vscode", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        guard fileManager.fileExists(atPath: extensionsDirectory.path) else {
            throw AntigravityExtensionDiscoveryError.notInstalled
        }

        let canonicalExtensionsDirectory = try canonicalExistingURL(
            extensionsDirectory,
            failure: .unsupportedInstallation("the extensions directory cannot be resolved")
        )
        let indexURL = canonicalExtensionsDirectory.appendingPathComponent("extensions.json")
        guard fileManager.fileExists(atPath: indexURL.path) else {
            throw AntigravityExtensionDiscoveryError.notInstalled
        }

        let records: [AntigravityExtensionIndexRecord]
        do {
            records = try JSONDecoder().decode(
                [AntigravityExtensionIndexRecord].self,
                from: Data(contentsOf: indexURL)
            )
        } catch {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                "extensions.json has an unexpected structure"
            )
        }

        let obsoleteNames = try readObsoleteNames(from: canonicalExtensionsDirectory)
        let activeRecords = records.filter { record in
            guard record.identifier.id == Self.extensionIdentifier,
                  record.location.scheme == "file",
                  let recordedPath = record.location.filePath else {
                return false
            }
            return !obsoleteNames.contains(
                URL(fileURLWithPath: recordedPath).lastPathComponent
            )
        }

        guard !activeRecords.isEmpty else {
            if records.contains(where: { $0.identifier.id == Self.extensionIdentifier }) {
                throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                    "no active installation is recorded"
                )
            }
            throw AntigravityExtensionDiscoveryError.notInstalled
        }
        guard activeRecords.count == 1,
              let record = activeRecords.first,
              let recordedPath = record.location.filePath else {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                "multiple active installations are recorded"
            )
        }

        let recordedRoot = URL(fileURLWithPath: recordedPath, isDirectory: true)
        guard fileManager.fileExists(atPath: recordedRoot.path) else {
            throw AntigravityExtensionDiscoveryError.incompleteInstallation(
                "the active extension directory is missing"
            )
        }
        let canonicalRoot = try canonicalExistingURL(
            recordedRoot,
            failure: .unsupportedInstallation("the active extension directory cannot be resolved")
        )
        guard isStrictDescendant(canonicalRoot, of: canonicalExtensionsDirectory) else {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                "the active extension directory is outside ~/.vscode/extensions"
            )
        }
        try validateOwnedDirectory(canonicalRoot)

        let package = try readPackage(from: canonicalRoot)
        guard package.publisher == Self.publisher,
              package.name == Self.extensionName else {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                "package.json publisher or name does not match google.google-antigravity"
            )
        }
        guard package.version == record.version else {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                "package.json version does not match extensions.json"
            )
        }

        let agyExecutable = homeDirectory.appendingPathComponent(Self.agyRelativePath)
            .standardizedFileURL
        let backendState = try validateAgyIfPresent(at: agyExecutable)
        return AntigravityInstallation(
            version: record.version,
            extensionRootPath: canonicalRoot.path,
            agyExecutablePath: agyExecutable.path,
            backendState: backendState
        )
    }

    private func readObsoleteNames(from extensionsDirectory: URL) throws -> Set<String> {
        let obsoleteURL = extensionsDirectory.appendingPathComponent(".obsolete")
        guard fileManager.fileExists(atPath: obsoleteURL.path) else {
            return []
        }
        do {
            let values = try JSONDecoder().decode(
                [String: Bool].self,
                from: Data(contentsOf: obsoleteURL)
            )
            return Set(values.compactMap { $0.value ? $0.key : nil })
        } catch {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                ".obsolete has an unexpected structure"
            )
        }
    }

    private func readPackage(from root: URL) throws -> AntigravityExtensionPackage {
        let packageURL = root.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw AntigravityExtensionDiscoveryError.incompleteInstallation(
                "package.json is missing"
            )
        }
        do {
            return try JSONDecoder().decode(
                AntigravityExtensionPackage.self,
                from: Data(contentsOf: packageURL)
            )
        } catch {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                "package.json has an unexpected structure"
            )
        }
    }

    private func validateOwnedDirectory(_ url: URL) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == expectedOwner else {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                "the active extension directory has an unexpected owner or type"
            )
        }
    }

    private func validateAgyIfPresent(
        at url: URL
    ) throws -> AntigravityBackendState {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            if errno == ENOENT {
                return .pendingDownload
            }
            throw AntigravityExtensionDiscoveryError.incompleteInstallation(
                "~/.gemini/bin/agy cannot be inspected"
            )
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                "~/.gemini/bin/agy is not a regular non-symlink file"
            )
        }
        guard information.st_uid == expectedOwner else {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                "~/.gemini/bin/agy has an unexpected owner"
            )
        }
        guard information.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0,
              fileManager.isExecutableFile(atPath: url.path) else {
            throw AntigravityExtensionDiscoveryError.incompleteInstallation(
                "~/.gemini/bin/agy is not executable"
            )
        }

        let canonicalExecutable = url.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalExecutable == url.standardizedFileURL else {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                "~/.gemini/bin/agy resolves outside its fixed path"
            )
        }
        try validateArm64MachO(at: canonicalExecutable)
        return .installed
    }

    private func validateArm64MachO(at url: URL) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AntigravityExtensionDiscoveryError.incompleteInstallation(
                "~/.gemini/bin/agy cannot be opened"
            )
        }
        defer { handle.closeFile() }

        let header: Data
        do {
            header = try handle.read(upToCount: 8) ?? Data()
        } catch {
            throw AntigravityExtensionDiscoveryError.incompleteInstallation(
                "~/.gemini/bin/agy cannot be read"
            )
        }
        let bytes = [UInt8](header)
        guard bytes.count == 8 else {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                "~/.gemini/bin/agy is not an arm64 Mach-O executable"
            )
        }
        let magic = littleEndianUInt32(bytes, offset: 0)
        let cpuType = littleEndianUInt32(bytes, offset: 4)
        guard magic == Self.machO64Magic,
              cpuType == Self.arm64CPUType else {
            throw AntigravityExtensionDiscoveryError.unsupportedInstallation(
                "~/.gemini/bin/agy is not an arm64 Mach-O executable"
            )
        }
    }

    private func littleEndianUInt32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private func canonicalExistingURL(
        _ url: URL,
        failure: AntigravityExtensionDiscoveryError
    ) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard fileManager.fileExists(atPath: resolved.path) else {
            throw failure
        }
        return resolved
    }

    private func isStrictDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        return candidateComponents.count > parentComponents.count
            && Array(candidateComponents.prefix(parentComponents.count)) == parentComponents
    }
}

private struct AntigravityExtensionIndexRecord: Decodable {
    struct Identifier: Decodable {
        let id: String
    }

    struct Location: Decodable {
        let scheme: String
        let path: String?
        let fsPath: String?

        var filePath: String? {
            if let fsPath, !fsPath.isEmpty {
                return fsPath
            }
            guard let path, !path.isEmpty else { return nil }
            return path.removingPercentEncoding ?? path
        }
    }

    let identifier: Identifier
    let version: String
    let location: Location
}

private struct AntigravityExtensionPackage: Decodable {
    let publisher: String
    let name: String
    let version: String
}
