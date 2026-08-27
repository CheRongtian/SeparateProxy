import Foundation
import SeparateProxyCore
import ServiceManagement

@MainActor
final class ProxyViewModel: ObservableObject {
    @Published var accessKeyInput = ""
    @Published var chromeIsSelected: Bool {
        didSet {
            UserDefaults.standard.set(chromeIsSelected, forKey: Self.chromeSelectionKey)
        }
    }
    @Published private(set) var keyIsSaved = false
    @Published private(set) var chrome: DiscoveredApplication?
    @Published private(set) var state: ProxyState = .helperNotInstalled
    @Published private(set) var message = "Helper setup is required."

    private static let chromeSelectionKey = "chrome-is-selected"
    private let keychain = KeychainStore()
    private let helperClient = HelperClient()
    private let helperService = SMAppService.daemon(
        plistName: SeparateProxyIdentifiers.helperPlist
    )

    init() {
        if UserDefaults.standard.object(forKey: Self.chromeSelectionKey) == nil {
            chromeIsSelected = true
        } else {
            chromeIsSelected = UserDefaults.standard.bool(forKey: Self.chromeSelectionKey)
        }
        refreshLocalState()
    }

    var canStart: Bool {
        let canRetry = state == .stopped || state == .error
        return canRetry
            && helperService.status == .enabled
            && keyIsSaved
            && chromeIsSelected
            && chrome != nil
    }

    var canStop: Bool {
        state == .running
    }

    var stateLabel: String {
        switch state {
        case .helperNotInstalled:
            return "Helper Not Installed"
        case .approvalRequired:
            return "Approval Required"
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .stopping:
            return "Stopping"
        case .error:
            return "Error"
        }
    }

    func saveAccessKey() {
        var candidate: String? = accessKeyInput
        defer {
            candidate = nil
            accessKeyInput = ""
        }

        do {
            guard let candidate else {
                throw OutlineAccessKeyError.emptyKey
            }
            _ = try OutlineAccessKeyParser.parse(candidate)
            try keychain.save(candidate)
            keyIsSaved = true
            message = "The Outline access key was saved in Keychain."
        } catch {
            message = error.localizedDescription
        }
    }

    func deleteAccessKey() {
        do {
            try keychain.delete()
            keyIsSaved = false
            accessKeyInput = ""
            message = "The Outline access key was removed from Keychain."
        } catch {
            message = error.localizedDescription
        }
    }

    func enableHelper() {
        do {
            try helperService.register()
            refreshHelperState()
        } catch {
            message = "Helper registration failed: \(error.localizedDescription)"
            refreshHelperState()
        }
    }

    func openHelperSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refresh() {
        refreshLocalState()
    }

    func start() {
        guard let chrome, chromeIsSelected else {
            state = .error
            message = "Google Chrome is unavailable or not selected."
            return
        }

        var accessKey: String?
        do {
            accessKey = try keychain.load()
            guard let accessKey else {
                throw KeychainStoreError.missingItem
            }
            state = .starting
            message = "Starting the proxy..."
            helperClient.start(
                accessKey: accessKey,
                chromeBundlePath: chrome.bundleURL.path
            ) { [weak self] result in
                Task { @MainActor in
                    self?.applyHelperResult(result)
                }
            }
        } catch {
            state = .error
            message = error.localizedDescription
        }
        accessKey = nil
    }

    func stop() {
        state = .stopping
        message = "Stopping the proxy..."
        helperClient.stop { [weak self] result in
            Task { @MainActor in
                self?.applyHelperResult(result)
            }
        }
    }

    private func refreshLocalState() {
        keyIsSaved = keychain.containsKey()
        chrome = ApplicationDiscovery.findGoogleChrome()
        refreshHelperState()
    }

    private func refreshHelperState() {
        switch helperService.status {
        case .notRegistered, .notFound:
            state = .helperNotInstalled
            message = "Enable the privileged helper to start the proxy."
        case .requiresApproval:
            state = .approvalRequired
            message = "Approve SeparateProxy in System Settings > General > Login Items."
        case .enabled:
            helperClient.status { [weak self] result in
                Task { @MainActor in
                    self?.applyHelperResult(result)
                }
            }
        @unknown default:
            state = .error
            message = "The privileged helper returned an unknown registration state."
        }
    }

    private func applyHelperResult(_ result: Result<NSDictionary, Error>) {
        switch result {
        case let .failure(error):
            state = .error
            message = error.localizedDescription
        case let .success(reply):
            guard let stateValue = reply[HelperReplyKey.state] as? String,
                  let newState = ProxyState(rawValue: stateValue),
                  let replyMessage = reply[HelperReplyKey.message] as? String else {
                state = .error
                message = HelperClientError.invalidReply.localizedDescription
                return
            }
            state = newState
            message = replyMessage
        }
    }
}
