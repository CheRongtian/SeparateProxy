import AppKit
import Darwin
import Foundation

struct StoredPreference<Value: Codable & Equatable>: Codable, Equatable {
    let existed: Bool
    let value: Value?

    init(existed: Bool, value: Value?) {
        self.existed = existed
        self.value = value
    }

    var isValid: Bool {
        existed == (value != nil)
    }
}

struct OriginalChromeDNSState: Codable, Equatable {
    let mode: StoredPreference<String>
    let templates: StoredPreference<String>
    let automaticModeFallbackToDoh: StoredPreference<Bool>

    var isValid: Bool {
        mode.isValid
            && templates.isValid
            && automaticModeFallbackToDoh.isValid
    }
}

enum ChromeDNSIntegrationState: Equatable {
    case notConfigured
    case chromeRunning
    case readyToConfigure
    case configuring
    case configured
    case modifiedExternally
    case unsupported(String)
    case error(String)
}

enum ChromeDNSRemovalResult: Equatable {
    case removed
    case settingsChangedExternally
    case notConfigured
}

enum ChromeDNSIntegrationError: LocalizedError {
    case chromeNotInstalled
    case chromeRunning
    case chromeDidNotQuit
    case localStateMissing
    case localStateNotRegularFile
    case localStateOwnerMismatch
    case malformedLocalState
    case unexpectedSchema(String)
    case missingOriginalState
    case invalidStoredState
    case fileOperation(String)

    var errorDescription: String? {
        switch self {
        case .chromeNotInstalled:
            return "Google Chrome is not installed."
        case .chromeRunning:
            return "Google Chrome must be completely closed before its DNS settings can be changed."
        case .chromeDidNotQuit:
            return "Google Chrome did not quit. No DNS settings were changed."
        case .localStateMissing:
            return "Chrome Local State was not found. Open Chrome once, quit it, and try again."
        case .localStateNotRegularFile:
            return "Chrome Local State is not a regular file."
        case .localStateOwnerMismatch:
            return "Chrome Local State is not owned by the current user."
        case .malformedLocalState:
            return "Chrome Local State contains malformed JSON."
        case let .unexpectedSchema(detail):
            return "Chrome Local State has an unsupported DNS schema: \(detail)"
        case .missingOriginalState:
            return "The original Chrome DNS settings are unavailable, so SeparateProxy did not change Chrome."
        case .invalidStoredState:
            return "The stored Chrome DNS integration state is invalid."
        case let .fileOperation(message):
            return "Chrome DNS file operation failed: \(message)"
        }
    }
}

protocol ChromeApplicationControlling: AnyObject {
    func isChromeRunning() -> Bool
    func requestChromeTermination() -> Bool
    func reopenChrome() throws
}

final class WorkspaceChromeApplicationController: ChromeApplicationControlling {
    private let bundleIdentifier = "com.google.Chrome"

    func isChromeRunning() -> Bool {
        !runningChromeApplications().isEmpty
    }

    func requestChromeTermination() -> Bool {
        let applications = runningChromeApplications()
        guard !applications.isEmpty else {
            return true
        }

        var requested = false
        for application in applications where application.bundleIdentifier == bundleIdentifier {
            requested = application.terminate() || requested
        }
        return requested
    }

    func reopenChrome() throws {
        guard let chromeURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            throw ChromeDNSIntegrationError.chromeNotInstalled
        }

        NSWorkspace.shared.openApplication(
            at: chromeURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                NSLog("SeparateProxy could not reopen Google Chrome: %@", error.localizedDescription)
            }
        }
    }

    private func runningChromeApplications() -> [NSRunningApplication] {
        let chromeURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        )?.standardizedFileURL

        return NSWorkspace.shared.runningApplications.filter { application in
            if application.bundleIdentifier == bundleIdentifier {
                return true
            }
            guard let chromeURL else {
                return false
            }
            return [application.bundleURL, application.executableURL]
                .compactMap { $0?.standardizedFileURL.path }
                .contains { path in
                    path == chromeURL.path || path.hasPrefix(chromeURL.path + "/")
                }
        }
    }
}

protocol ChromeDNSLocalStateWriting {
    func replaceFile(
        at url: URL,
        with data: Data,
        preserving metadata: ChromeDNSFileMetadata
    ) throws
}

struct ChromeDNSFileMetadata: Equatable {
    let permissions: mode_t
    let owner: uid_t
    let group: gid_t
}

final class POSIXChromeDNSLocalStateWriter: ChromeDNSLocalStateWriting {
    func replaceFile(
        at url: URL,
        with data: Data,
        preserving metadata: ChromeDNSFileMetadata
    ) throws {
        let directoryURL = url.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(url.lastPathComponent).separateproxy.\(UUID().uuidString).tmp"
        )
        let temporaryPath = temporaryURL.path
        var descriptor: Int32 = -1
        var renamed = false

        defer {
            if descriptor >= 0 {
                Darwin.close(descriptor)
            }
            if !renamed {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        descriptor = Darwin.open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            metadata.permissions
        )
        guard descriptor >= 0 else {
            throw posixError("create temporary Local State file")
        }

        try writeAll(data, to: descriptor)

        guard Darwin.fchmod(descriptor, metadata.permissions) == 0 else {
            throw posixError("preserve Local State permissions")
        }

        var temporaryInfo = stat()
        guard Darwin.fstat(descriptor, &temporaryInfo) == 0 else {
            throw posixError("inspect temporary Local State file")
        }
        guard temporaryInfo.st_uid == metadata.owner,
              temporaryInfo.st_gid == metadata.group else {
            throw ChromeDNSIntegrationError.fileOperation(
                "the temporary file owner or group did not match Local State"
            )
        }

        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("flush temporary Local State file")
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw posixError("close temporary Local State file")
        }
        descriptor = -1

        let directoryDescriptor = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY)
        guard directoryDescriptor >= 0 else {
            throw posixError("open the Chrome data directory for synchronization")
        }
        defer { Darwin.close(directoryDescriptor) }

        guard Darwin.rename(temporaryPath, url.path) == 0 else {
            throw posixError("atomically replace Chrome Local State")
        }
        renamed = true

        // The rename is the atomic commit point. A directory fsync failure cannot
        // safely roll it back, so durability synchronization is best-effort here.
        _ = Darwin.fsync(directoryDescriptor)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw posixError("write temporary Local State file")
                }
                guard written > 0 else {
                    throw ChromeDNSIntegrationError.fileOperation(
                        "writing the temporary Local State file made no progress"
                    )
                }
                offset += written
            }
        }
    }

    private func posixError(_ operation: String) -> ChromeDNSIntegrationError {
        let message = String(cString: strerror(errno))
        return .fileOperation("\(operation): \(message)")
    }
}

private enum ChromeDNSIntegrationPhase: String, Codable {
    case preparing
    case installed
    case modifiedExternally
}

private struct ChromeDNSIntegrationRecord: Codable {
    let version: Int
    let phase: ChromeDNSIntegrationPhase
    let original: OriginalChromeDNSState
}

private final class ChromeDNSIntegrationStore {
    private let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func load() throws -> ChromeDNSIntegrationRecord? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let record = try JSONDecoder().decode(
                ChromeDNSIntegrationRecord.self,
                from: Data(contentsOf: url)
            )
            guard record.version == 1, record.original.isValid else {
                throw ChromeDNSIntegrationError.invalidStoredState
            }
            return record
        } catch let error as ChromeDNSIntegrationError {
            throw error
        } catch {
            throw ChromeDNSIntegrationError.invalidStoredState
        }
    }

    func save(phase: ChromeDNSIntegrationPhase, original: OriginalChromeDNSState) throws {
        guard original.isValid else {
            throw ChromeDNSIntegrationError.invalidStoredState
        }
        let directoryURL = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let record = ChromeDNSIntegrationRecord(
                version: 1,
                phase: phase,
                original: original
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch let error as ChromeDNSIntegrationError {
            throw error
        } catch {
            throw ChromeDNSIntegrationError.fileOperation(
                "save the DNS integration state: \(error.localizedDescription)"
            )
        }
    }

    func remove() throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw ChromeDNSIntegrationError.fileOperation(
                "remove the DNS integration state: \(error.localizedDescription)"
            )
        }
    }
}

final class ChromeDNSManager {
    static let cloudflareTemplates = """
    {
       "servers": [ {
          "endpoints": [ {
             "ips": [ "1.1.1.1", "1.0.0.1" ]
          } ],
          "template": "https://one.one.one.one/dns-query{?dns}"
       } ]
    }
    """

    private static let modeKey = "mode"
    private static let templatesKey = "templates"
    private static let fallbackKey = "automatic_mode_fallback_to_doh"
    private static let dnsKey = "dns_over_https"

    private let localStateURL: URL
    private let integrationStore: ChromeDNSIntegrationStore
    private let applicationController: ChromeApplicationControlling
    private let localStateWriter: ChromeDNSLocalStateWriting
    private let fileManager: FileManager

    convenience init() {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let localStateURL = applicationSupportURL
            .appendingPathComponent("Google/Chrome", isDirectory: true)
            .appendingPathComponent("Local State")
        let integrationStateURL = applicationSupportURL
            .appendingPathComponent("SeparateProxy", isDirectory: true)
            .appendingPathComponent("chrome-dns-integration.json")
        self.init(
            localStateURL: localStateURL,
            integrationStateURL: integrationStateURL,
            applicationController: WorkspaceChromeApplicationController(),
            localStateWriter: POSIXChromeDNSLocalStateWriter()
        )
    }

    init(
        localStateURL: URL,
        integrationStateURL: URL,
        applicationController: ChromeApplicationControlling,
        localStateWriter: ChromeDNSLocalStateWriting,
        fileManager: FileManager = .default
    ) {
        self.localStateURL = localStateURL
        integrationStore = ChromeDNSIntegrationStore(
            url: integrationStateURL,
            fileManager: fileManager
        )
        self.applicationController = applicationController
        self.localStateWriter = localStateWriter
        self.fileManager = fileManager
    }

    func integrationState() -> ChromeDNSIntegrationState {
        do {
            let record = try integrationStore.load()
            if record?.phase == .modifiedExternally {
                return .modifiedExternally
            }

            let document = try readLocalState()
            if targetMatches(document.dns) {
                return .configured
            }
            if record?.phase == .installed {
                return .modifiedExternally
            }
            return isChromeRunning() ? .chromeRunning : .readyToConfigure
        } catch let error as ChromeDNSIntegrationError {
            switch error {
            case .localStateMissing,
                 .localStateNotRegularFile,
                 .localStateOwnerMismatch,
                 .unexpectedSchema:
                return .unsupported(error.localizedDescription)
            default:
                return .error(error.localizedDescription)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    func isChromeRunning() -> Bool {
        applicationController.isChromeRunning()
    }

    func requestChromeTermination() -> Bool {
        applicationController.requestChromeTermination()
    }

    func reopenChrome() throws {
        try applicationController.reopenChrome()
    }

    func hasRestorableIntegration() -> Bool {
        guard let record = try? integrationStore.load() else {
            return false
        }
        return record.phase == .preparing || record.phase == .installed
    }

    func configure() throws {
        guard !isChromeRunning() else {
            throw ChromeDNSIntegrationError.chromeRunning
        }

        var document = try readLocalState()
        if targetMatches(document.dns),
           let record = try integrationStore.load(),
           record.phase != .modifiedExternally {
            return
        }

        let original = try captureOriginalState(from: document.dns)
        try integrationStore.save(phase: .preparing, original: original)

        document.dns[Self.modeKey] = "automatic"
        document.dns[Self.templatesKey] = Self.cloudflareTemplates
        document.dns[Self.fallbackKey] = false
        document.root[Self.dnsKey] = document.dns

        guard !isChromeRunning() else {
            try? integrationStore.remove()
            throw ChromeDNSIntegrationError.chromeRunning
        }

        do {
            let data = try encodedLocalState(document.root)
            try localStateWriter.replaceFile(
                at: localStateURL,
                with: data,
                preserving: document.metadata
            )
        } catch {
            try? integrationStore.remove()
            throw error
        }

        try integrationStore.save(phase: .installed, original: original)
    }

    func removeIntegration() throws -> ChromeDNSRemovalResult {
        guard let record = try integrationStore.load() else {
            return .notConfigured
        }
        if record.phase == .modifiedExternally {
            return .settingsChangedExternally
        }

        var document = try readLocalState()
        guard targetMatches(document.dns) else {
            try integrationStore.save(
                phase: .modifiedExternally,
                original: record.original
            )
            return .settingsChangedExternally
        }

        guard !isChromeRunning() else {
            throw ChromeDNSIntegrationError.chromeRunning
        }

        restore(record.original.mode, key: Self.modeKey, in: &document.dns)
        restore(record.original.templates, key: Self.templatesKey, in: &document.dns)
        restore(
            record.original.automaticModeFallbackToDoh,
            key: Self.fallbackKey,
            in: &document.dns
        )
        document.root[Self.dnsKey] = document.dns

        guard !isChromeRunning() else {
            throw ChromeDNSIntegrationError.chromeRunning
        }

        let data = try encodedLocalState(document.root)
        try localStateWriter.replaceFile(
            at: localStateURL,
            with: data,
            preserving: document.metadata
        )
        try integrationStore.remove()
        return .removed
    }

    private struct LocalStateDocument {
        var root: [String: Any]
        var dns: [String: Any]
        let metadata: ChromeDNSFileMetadata
    }

    private func readLocalState() throws -> LocalStateDocument {
        guard fileManager.fileExists(atPath: localStateURL.path) else {
            throw ChromeDNSIntegrationError.localStateMissing
        }

        var fileInfo = stat()
        guard Darwin.lstat(localStateURL.path, &fileInfo) == 0 else {
            throw ChromeDNSIntegrationError.fileOperation(
                "inspect Chrome Local State: \(String(cString: strerror(errno)))"
            )
        }
        guard (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw ChromeDNSIntegrationError.localStateNotRegularFile
        }
        guard fileInfo.st_uid == Darwin.geteuid() else {
            throw ChromeDNSIntegrationError.localStateOwnerMismatch
        }

        let data: Data
        do {
            data = try Data(contentsOf: localStateURL, options: .mappedIfSafe)
        } catch {
            throw ChromeDNSIntegrationError.fileOperation(
                "read Chrome Local State: \(error.localizedDescription)"
            )
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ChromeDNSIntegrationError.malformedLocalState
        }
        guard let root = object as? [String: Any] else {
            throw ChromeDNSIntegrationError.unexpectedSchema(
                "the top-level value is not an object"
            )
        }

        let dns: [String: Any]
        if let value = root[Self.dnsKey] {
            guard let dictionary = value as? [String: Any] else {
                throw ChromeDNSIntegrationError.unexpectedSchema(
                    "dns_over_https is not an object"
                )
            }
            dns = dictionary
        } else {
            dns = [:]
        }

        _ = try captureOriginalState(from: dns)

        return LocalStateDocument(
            root: root,
            dns: dns,
            metadata: ChromeDNSFileMetadata(
                permissions: fileInfo.st_mode & 0o7777,
                owner: fileInfo.st_uid,
                group: fileInfo.st_gid
            )
        )
    }

    private func captureOriginalState(
        from dns: [String: Any]
    ) throws -> OriginalChromeDNSState {
        OriginalChromeDNSState(
            mode: try stringPreference(Self.modeKey, in: dns),
            templates: try stringPreference(Self.templatesKey, in: dns),
            automaticModeFallbackToDoh: try boolPreference(Self.fallbackKey, in: dns)
        )
    }

    private func stringPreference(
        _ key: String,
        in dictionary: [String: Any]
    ) throws -> StoredPreference<String> {
        guard let value = dictionary[key] else {
            return StoredPreference(existed: false, value: nil)
        }
        guard let string = value as? String else {
            throw ChromeDNSIntegrationError.unexpectedSchema("\(key) is not a string")
        }
        return StoredPreference(existed: true, value: string)
    }

    private func boolPreference(
        _ key: String,
        in dictionary: [String: Any]
    ) throws -> StoredPreference<Bool> {
        guard let value = dictionary[key] else {
            return StoredPreference(existed: false, value: nil)
        }
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
              let number = value as? NSNumber else {
            throw ChromeDNSIntegrationError.unexpectedSchema("\(key) is not a boolean")
        }
        return StoredPreference(existed: true, value: number.boolValue)
    }

    private func targetMatches(_ dns: [String: Any]) -> Bool {
        guard dns[Self.modeKey] as? String == "automatic",
              dns[Self.templatesKey] as? String == Self.cloudflareTemplates,
              let fallback = dns[Self.fallbackKey],
              CFGetTypeID(fallback as CFTypeRef) == CFBooleanGetTypeID(),
              let number = fallback as? NSNumber else {
            return false
        }
        return !number.boolValue
    }

    private func restore<Value: Codable & Equatable>(
        _ preference: StoredPreference<Value>,
        key: String,
        in dictionary: inout [String: Any]
    ) {
        if preference.existed, let value = preference.value {
            dictionary[key] = value
        } else {
            dictionary.removeValue(forKey: key)
        }
    }

    private func encodedLocalState(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw ChromeDNSIntegrationError.unexpectedSchema(
                "the updated document cannot be encoded as JSON"
            )
        }
        do {
            var data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            data.append(0x0A)
            return data
        } catch {
            throw ChromeDNSIntegrationError.fileOperation(
                "encode Chrome Local State: \(error.localizedDescription)"
            )
        }
    }
}
