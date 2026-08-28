import Darwin
import Foundation

public struct CodexInstallation: Equatable, Sendable {
    public let version: String
    public let extensionRootPath: String
    public let executablePath: String

    public init(version: String, extensionRootPath: String, executablePath: String) {
        self.version = version
        self.extensionRootPath = extensionRootPath
        self.executablePath = executablePath
    }
}

public enum CodexExtensionDiscoveryError: LocalizedError, Equatable {
    case notInstalled
    case incompleteInstallation(String)
    case unsupportedInstallation(String)
    case consoleUserUnavailable

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The OpenAI Codex VS Code extension is not installed."
        case let .incompleteInstallation(reason):
            return "The OpenAI Codex VS Code extension installation is incomplete: \(reason)"
        case let .unsupportedInstallation(reason):
            return "The OpenAI Codex VS Code extension installation is unsupported: \(reason)"
        case .consoleUserUnavailable:
            return "The current console user is unavailable."
        }
    }
}

public struct CodexExtensionDiscovery {
    public static let extensionIdentifier = "openai.chatgpt"
    public static let publisher = "openai"
    public static let extensionName = "chatgpt"
    public static let targetPlatform = "darwin-arm64"
    public static let executableRelativePath = "bin/macos-aarch64/codex"

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
    ) throws -> CodexExtensionDiscovery {
        var consoleInformation = stat()
        guard lstat("/dev/console", &consoleInformation) == 0,
              consoleInformation.st_uid > 0,
              let record = getpwuid(consoleInformation.st_uid),
              let home = record.pointee.pw_dir else {
            throw CodexExtensionDiscoveryError.consoleUserUnavailable
        }

        return CodexExtensionDiscovery(
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
        discovery: () throws -> CodexInstallation
    ) rethrows -> CodexInstallation? {
        guard enabled else { return nil }
        return try discovery()
    }

    public func discoverActiveInstallation() throws -> CodexInstallation {
        let extensionsDirectory = homeDirectory
            .appendingPathComponent(".vscode", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        guard fileManager.fileExists(atPath: extensionsDirectory.path) else {
            throw CodexExtensionDiscoveryError.notInstalled
        }

        let canonicalExtensionsDirectory = try canonicalExistingURL(
            extensionsDirectory,
            failure: .unsupportedInstallation("the extensions directory cannot be resolved")
        )
        let indexURL = canonicalExtensionsDirectory.appendingPathComponent("extensions.json")
        guard fileManager.fileExists(atPath: indexURL.path) else {
            throw CodexExtensionDiscoveryError.notInstalled
        }

        let records: [ExtensionIndexRecord]
        do {
            records = try JSONDecoder().decode(
                [ExtensionIndexRecord].self,
                from: Data(contentsOf: indexURL)
            )
        } catch {
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                "extensions.json has an unexpected structure"
            )
        }

        let obsoleteNames = try readObsoleteNames(from: canonicalExtensionsDirectory)
        let activeRecords = records.filter { record in
            guard record.identifier.id == Self.extensionIdentifier,
                  record.location.scheme == "file",
                  record.metadata?.targetPlatform == Self.targetPlatform,
                  let recordedPath = record.location.filePath else {
                return false
            }
            return !obsoleteNames.contains(
                URL(fileURLWithPath: recordedPath).lastPathComponent
            )
        }

        guard !activeRecords.isEmpty else {
            let hasCodexRecord = records.contains {
                $0.identifier.id == Self.extensionIdentifier
            }
            if hasCodexRecord {
                throw CodexExtensionDiscoveryError.unsupportedInstallation(
                    "no active darwin-arm64 installation is recorded"
                )
            }
            throw CodexExtensionDiscoveryError.notInstalled
        }
        guard activeRecords.count == 1,
              let record = activeRecords.first,
              let recordedPath = record.location.filePath else {
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                "multiple active darwin-arm64 installations are recorded"
            )
        }

        let recordedRoot = URL(fileURLWithPath: recordedPath, isDirectory: true)
        guard fileManager.fileExists(atPath: recordedRoot.path) else {
            throw CodexExtensionDiscoveryError.incompleteInstallation(
                "the active extension directory is missing"
            )
        }
        let canonicalRoot = try canonicalExistingURL(
            recordedRoot,
            failure: .unsupportedInstallation("the active extension directory cannot be resolved")
        )
        guard isStrictDescendant(canonicalRoot, of: canonicalExtensionsDirectory) else {
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                "the active extension directory is outside ~/.vscode/extensions"
            )
        }
        try validateOwnedDirectory(canonicalRoot)

        let package = try readPackage(from: canonicalRoot)
        guard package.publisher == Self.publisher,
              package.name == Self.extensionName else {
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                "package.json publisher or name does not match openai.chatgpt"
            )
        }
        guard package.version == record.version else {
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                "package.json version does not match extensions.json"
            )
        }
        if let packagePlatform = package.metadata?.targetPlatform,
           packagePlatform != Self.targetPlatform {
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                "package.json target platform is not darwin-arm64"
            )
        }

        let executable = try validateExecutable(
            at: canonicalRoot.appendingPathComponent(Self.executableRelativePath),
            extensionRoot: canonicalRoot
        )
        return CodexInstallation(
            version: record.version,
            extensionRootPath: canonicalRoot.path,
            executablePath: executable.path
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
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                ".obsolete has an unexpected structure"
            )
        }
    }

    private func readPackage(from root: URL) throws -> ExtensionPackage {
        let packageURL = root.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw CodexExtensionDiscoveryError.incompleteInstallation(
                "package.json is missing"
            )
        }
        do {
            return try JSONDecoder().decode(
                ExtensionPackage.self,
                from: Data(contentsOf: packageURL)
            )
        } catch {
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                "package.json has an unexpected structure"
            )
        }
    }

    private func validateOwnedDirectory(_ url: URL) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == expectedOwner else {
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                "the active extension directory has an unexpected owner or type"
            )
        }
    }

    private func validateExecutable(at url: URL, extensionRoot: URL) throws -> URL {
        guard url.lastPathComponent == "codex" else {
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                "the executable basename is not codex"
            )
        }

        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw CodexExtensionDiscoveryError.incompleteInstallation(
                "bin/macos-aarch64/codex is missing"
            )
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                "bin/macos-aarch64/codex is not a regular non-symlink file"
            )
        }
        guard information.st_uid == expectedOwner else {
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                "bin/macos-aarch64/codex has an unexpected owner"
            )
        }
        guard information.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else {
            throw CodexExtensionDiscoveryError.incompleteInstallation(
                "bin/macos-aarch64/codex is not executable"
            )
        }

        let canonicalExecutable = try canonicalExistingURL(
            url,
            failure: .unsupportedInstallation("the Codex executable cannot be resolved")
        )
        guard isStrictDescendant(canonicalExecutable, of: extensionRoot),
              canonicalExecutable.lastPathComponent == "codex" else {
            throw CodexExtensionDiscoveryError.unsupportedInstallation(
                "the Codex executable resolves outside its validated extension"
            )
        }
        return canonicalExecutable
    }

    private func canonicalExistingURL(
        _ url: URL,
        failure: CodexExtensionDiscoveryError
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

private struct ExtensionIndexRecord: Decodable {
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

    struct Metadata: Decodable {
        let targetPlatform: String?
    }

    let identifier: Identifier
    let version: String
    let location: Location
    let metadata: Metadata?
}

private struct ExtensionPackage: Decodable {
    struct Metadata: Decodable {
        let targetPlatform: String?
    }

    let publisher: String
    let name: String
    let version: String
    let metadata: Metadata?

    enum CodingKeys: String, CodingKey {
        case publisher, name, version
        case metadata = "__metadata"
    }
}
