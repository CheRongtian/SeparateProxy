import CoreFoundation
import Darwin
import Foundation

struct OriginalChromeECHState: Codable, Equatable {
    let sslObjectExisted: Bool
    let echEnabled: StoredPreference<Bool>

    var isValid: Bool {
        echEnabled.isValid
    }
}

enum ChromeECHRequirementState: Equatable {
    case notConfigured
    case chromeRunning
    case configured
    case satisfiedByManagedPolicy
    case modifiedExternally
    case managedEnabled
    case unsupported(String)
    case error(String)
}

enum ChromeECHRemovalResult: Equatable {
    case removed
    case settingsChangedExternally
    case notConfigured
}

enum ChromeECHIntegrationError: LocalizedError {
    case chromeRunning
    case localStateMissing
    case localStateNotRegularFile
    case localStateOwnerMismatch
    case malformedLocalState
    case unexpectedSchema(String)
    case managedPolicyEnablesECH
    case invalidManagedPolicy
    case invalidStoredState
    case fileOperation(String)

    var errorDescription: String? {
        switch self {
        case .chromeRunning:
            return "Google Chrome must be completely closed before Encrypted ClientHello can be changed."
        case .localStateMissing:
            return "Chrome Local State was not found. Open Chrome once, quit it, and try again."
        case .localStateNotRegularFile:
            return "Chrome Local State is not a regular file."
        case .localStateOwnerMismatch:
            return "Chrome Local State is not owned by the current user."
        case .malformedLocalState:
            return "Chrome Local State contains malformed JSON."
        case let .unexpectedSchema(detail):
            return "Chrome Local State has an unsupported ECH schema: \(detail)"
        case .managedPolicyEnablesECH:
            return "A managed Chrome policy enables Encrypted ClientHello. Proxy Websites cannot start while that policy is active."
        case .invalidManagedPolicy:
            return "Chrome's managed EncryptedClientHelloEnabled policy has an unsupported value."
        case .invalidStoredState:
            return "The stored Chrome ECH integration state is invalid."
        case let .fileOperation(message):
            return "Chrome ECH file operation failed: \(message)"
        }
    }
}

enum ChromeECHManagedPolicyState: Equatable {
    case notManaged
    case enabled
    case disabled
    case invalid
}

protocol ChromeECHPolicyProviding {
    func managedPolicyState() -> ChromeECHManagedPolicyState
}

struct SystemChromeECHPolicyProvider: ChromeECHPolicyProviding {
    private let key = "EncryptedClientHelloEnabled" as CFString
    private let applicationIdentifier = "com.google.Chrome" as CFString

    func managedPolicyState() -> ChromeECHManagedPolicyState {
        guard CFPreferencesAppValueIsForced(key, applicationIdentifier) else {
            return .notManaged
        }
        guard let value = CFPreferencesCopyAppValue(key, applicationIdentifier) else {
            return .invalid
        }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean)) ? .enabled : .disabled
        }
        return .invalid
    }
}

private enum ChromeECHIntegrationPhase: String, Codable {
    case preparing
    case installed
    case modifiedExternally
}

private struct ChromeECHIntegrationRecord: Codable {
    let version: Int
    let phase: ChromeECHIntegrationPhase
    let original: OriginalChromeECHState
}

private final class ChromeECHIntegrationStore {
    private let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager) {
        self.url = url
        self.fileManager = fileManager
    }

    func load() throws -> ChromeECHIntegrationRecord? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let record = try JSONDecoder().decode(
                ChromeECHIntegrationRecord.self,
                from: Data(contentsOf: url)
            )
            guard record.version == 1, record.original.isValid else {
                throw ChromeECHIntegrationError.invalidStoredState
            }
            return record
        } catch let error as ChromeECHIntegrationError {
            throw error
        } catch {
            throw ChromeECHIntegrationError.invalidStoredState
        }
    }

    func save(
        phase: ChromeECHIntegrationPhase,
        original: OriginalChromeECHState
    ) throws {
        guard original.isValid else {
            throw ChromeECHIntegrationError.invalidStoredState
        }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let record = ChromeECHIntegrationRecord(
                version: 1,
                phase: phase,
                original: original
            )
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch let error as ChromeECHIntegrationError {
            throw error
        } catch {
            throw ChromeECHIntegrationError.fileOperation(
                "save the ECH integration state: \(error.localizedDescription)"
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
            throw ChromeECHIntegrationError.fileOperation(
                "remove the ECH integration state: \(error.localizedDescription)"
            )
        }
    }
}

final class ChromeECHManager {
    private static let sslKey = "ssl"
    private static let echEnabledKey = "ech_enabled"

    private let localStateURL: URL
    private let integrationStore: ChromeECHIntegrationStore
    private let applicationController: ChromeApplicationControlling
    private let localStateWriter: ChromeDNSLocalStateWriting
    private let policyProvider: ChromeECHPolicyProviding
    private let fileManager: FileManager

    convenience init() {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.init(
            localStateURL: applicationSupportURL
                .appendingPathComponent("Google/Chrome", isDirectory: true)
                .appendingPathComponent("Local State"),
            integrationStateURL: applicationSupportURL
                .appendingPathComponent("SeparateProxy", isDirectory: true)
                .appendingPathComponent("chrome-ech-integration.json"),
            applicationController: WorkspaceChromeApplicationController(),
            localStateWriter: POSIXChromeDNSLocalStateWriter(),
            policyProvider: SystemChromeECHPolicyProvider()
        )
    }

    init(
        localStateURL: URL,
        integrationStateURL: URL,
        applicationController: ChromeApplicationControlling,
        localStateWriter: ChromeDNSLocalStateWriting,
        policyProvider: ChromeECHPolicyProviding,
        fileManager: FileManager = .default
    ) {
        self.localStateURL = localStateURL
        integrationStore = ChromeECHIntegrationStore(
            url: integrationStateURL,
            fileManager: fileManager
        )
        self.applicationController = applicationController
        self.localStateWriter = localStateWriter
        self.policyProvider = policyProvider
        self.fileManager = fileManager
    }

    func requirementState() -> ChromeECHRequirementState {
        switch policyProvider.managedPolicyState() {
        case .enabled:
            return .managedEnabled
        case .disabled:
            return .satisfiedByManagedPolicy
        case .invalid:
            return .unsupported(ChromeECHIntegrationError.invalidManagedPolicy.localizedDescription)
        case .notManaged:
            break
        }

        do {
            let record = try integrationStore.load()
            if record?.phase == .modifiedExternally {
                return .modifiedExternally
            }
            let document = try readLocalState()
            if document.ssl[Self.echEnabledKey] as? Bool == false {
                return .configured
            }
            if record?.phase == .installed {
                return .modifiedExternally
            }
            return applicationController.isChromeRunning()
                ? .chromeRunning
                : .notConfigured
        } catch let error as ChromeECHIntegrationError {
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

    func isRequirementSatisfied() throws -> Bool {
        switch policyProvider.managedPolicyState() {
        case .enabled:
            throw ChromeECHIntegrationError.managedPolicyEnablesECH
        case .disabled:
            return true
        case .invalid:
            throw ChromeECHIntegrationError.invalidManagedPolicy
        case .notManaged:
            let document = try readLocalState()
            return document.ssl[Self.echEnabledKey] as? Bool == false
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
        switch policyProvider.managedPolicyState() {
        case .enabled:
            throw ChromeECHIntegrationError.managedPolicyEnablesECH
        case .disabled:
            return
        case .invalid:
            throw ChromeECHIntegrationError.invalidManagedPolicy
        case .notManaged:
            break
        }
        guard !isChromeRunning() else {
            throw ChromeECHIntegrationError.chromeRunning
        }

        var document = try readLocalState()
        if document.ssl[Self.echEnabledKey] as? Bool == false {
            if let record = try integrationStore.load() {
                if record.phase == .preparing {
                    try integrationStore.save(
                        phase: .installed,
                        original: record.original
                    )
                }
            } else {
                let original = OriginalChromeECHState(
                    sslObjectExisted: document.sslObjectExisted,
                    echEnabled: try boolPreference(Self.echEnabledKey, in: document.ssl)
                )
                try integrationStore.save(phase: .installed, original: original)
            }
            return
        }
        let original = OriginalChromeECHState(
            sslObjectExisted: document.sslObjectExisted,
            echEnabled: try boolPreference(Self.echEnabledKey, in: document.ssl)
        )
        try integrationStore.save(phase: .preparing, original: original)
        document.ssl[Self.echEnabledKey] = false
        document.root[Self.sslKey] = document.ssl

        guard !isChromeRunning() else {
            try? integrationStore.remove()
            throw ChromeECHIntegrationError.chromeRunning
        }
        do {
            try localStateWriter.replaceFile(
                at: localStateURL,
                with: try encodedLocalState(document.root),
                preserving: document.metadata
            )
        } catch {
            try? integrationStore.remove()
            throw error
        }
        try integrationStore.save(phase: .installed, original: original)
    }

    func removeIntegration() throws -> ChromeECHRemovalResult {
        guard let record = try integrationStore.load() else {
            return .notConfigured
        }
        if record.phase == .modifiedExternally {
            return .settingsChangedExternally
        }
        var document = try readLocalState()
        guard document.ssl[Self.echEnabledKey] as? Bool == false else {
            try integrationStore.save(
                phase: .modifiedExternally,
                original: record.original
            )
            return .settingsChangedExternally
        }
        guard !isChromeRunning() else {
            throw ChromeECHIntegrationError.chromeRunning
        }

        restore(record.original.echEnabled, in: &document.ssl)
        if !record.original.sslObjectExisted && document.ssl.isEmpty {
            document.root.removeValue(forKey: Self.sslKey)
        } else {
            document.root[Self.sslKey] = document.ssl
        }
        guard !isChromeRunning() else {
            throw ChromeECHIntegrationError.chromeRunning
        }
        try localStateWriter.replaceFile(
            at: localStateURL,
            with: try encodedLocalState(document.root),
            preserving: document.metadata
        )
        try integrationStore.remove()
        return .removed
    }

    private struct LocalStateDocument {
        var root: [String: Any]
        var ssl: [String: Any]
        let sslObjectExisted: Bool
        let metadata: ChromeDNSFileMetadata
    }

    private func readLocalState() throws -> LocalStateDocument {
        guard fileManager.fileExists(atPath: localStateURL.path) else {
            throw ChromeECHIntegrationError.localStateMissing
        }
        var info = stat()
        guard Darwin.lstat(localStateURL.path, &info) == 0 else {
            throw ChromeECHIntegrationError.fileOperation(
                "inspect Chrome Local State: \(String(cString: strerror(errno)))"
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ChromeECHIntegrationError.localStateNotRegularFile
        }
        guard info.st_uid == Darwin.geteuid() else {
            throw ChromeECHIntegrationError.localStateOwnerMismatch
        }
        let data: Data
        do {
            data = try Data(contentsOf: localStateURL, options: .mappedIfSafe)
        } catch {
            throw ChromeECHIntegrationError.fileOperation(
                "read Chrome Local State: \(error.localizedDescription)"
            )
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ChromeECHIntegrationError.malformedLocalState
        }
        guard let root = object as? [String: Any] else {
            throw ChromeECHIntegrationError.unexpectedSchema(
                "the top-level value is not an object"
            )
        }
        let sslObjectExisted = root[Self.sslKey] != nil
        let ssl: [String: Any]
        if let value = root[Self.sslKey] {
            guard let dictionary = value as? [String: Any] else {
                throw ChromeECHIntegrationError.unexpectedSchema("ssl is not an object")
            }
            ssl = dictionary
        } else {
            ssl = [:]
        }
        _ = try boolPreference(Self.echEnabledKey, in: ssl)
        return LocalStateDocument(
            root: root,
            ssl: ssl,
            sslObjectExisted: sslObjectExisted,
            metadata: .init(
                permissions: info.st_mode & 0o7777,
                owner: info.st_uid,
                group: info.st_gid
            )
        )
    }

    private func boolPreference(
        _ key: String,
        in dictionary: [String: Any]
    ) throws -> StoredPreference<Bool> {
        guard let value = dictionary[key] else {
            return .init(existed: false, value: nil)
        }
        guard let boolValue = value as? Bool else {
            throw ChromeECHIntegrationError.unexpectedSchema("\(key) is not a Boolean")
        }
        return .init(existed: true, value: boolValue)
    }

    private func restore(
        _ preference: StoredPreference<Bool>,
        in dictionary: inout [String: Any]
    ) {
        if preference.existed, let value = preference.value {
            dictionary[Self.echEnabledKey] = value
        } else {
            dictionary.removeValue(forKey: Self.echEnabledKey)
        }
    }

    private func encodedLocalState(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw ChromeECHIntegrationError.malformedLocalState
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw ChromeECHIntegrationError.malformedLocalState
        }
    }
}
