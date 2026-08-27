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
    @Published private(set) var chromeDNSState: ChromeDNSIntegrationState = .notConfigured
    @Published private(set) var chromeDNSMessage = "Chrome DNS integration has not been checked."
    @Published private(set) var chromeDNSCanRemove = false

    private static let chromeSelectionKey = "chrome-is-selected"
    private let keychain = KeychainStore()
    private let helperClient = HelperClient()
    private let chromeDNSManager = ChromeDNSManager()
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

    var chromeDNSStateLabel: String {
        switch chromeDNSState {
        case .notConfigured:
            return "Not Configured"
        case .chromeRunning:
            return "Chrome Is Running"
        case .readyToConfigure:
            return "Ready to Configure"
        case .configuring:
            return "Configuring"
        case .configured:
            return "Configured"
        case .modifiedExternally:
            return "Changed Externally"
        case .unsupported:
            return "Unsupported"
        case .error:
            return "Error"
        }
    }

    var chromeDNSConfigureButtonTitle: String {
        chromeDNSManager.isChromeRunning()
            ? "Quit and Configure Chrome"
            : "Configure Chrome DNS"
    }

    var chromeDNSRemoveButtonTitle: String {
        chromeDNSManager.isChromeRunning()
            ? "Quit and Remove Chrome DNS Integration"
            : "Remove Chrome DNS Integration"
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

    func configureChromeDNS() {
        beginChromeDNSOperation(.configure)
    }

    func removeChromeDNSIntegration() {
        if chromeDNSState == .modifiedExternally {
            performChromeDNSOperation(.remove, reopenChrome: false)
            return
        }
        beginChromeDNSOperation(.remove)
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
        refreshChromeDNSState()
        refreshHelperState()
    }

    private enum ChromeDNSOperation {
        case configure
        case remove
    }

    private func beginChromeDNSOperation(_ operation: ChromeDNSOperation) {
        let chromeWasRunning = chromeDNSManager.isChromeRunning()
        guard chromeWasRunning else {
            performChromeDNSOperation(operation, reopenChrome: false)
            return
        }

        chromeDNSState = .configuring
        chromeDNSMessage = "Waiting for Google Chrome to quit safely..."
        guard chromeDNSManager.requestChromeTermination() else {
            chromeDNSState = .error(ChromeDNSIntegrationError.chromeDidNotQuit.localizedDescription)
            chromeDNSMessage = ChromeDNSIntegrationError.chromeDidNotQuit.localizedDescription
            return
        }
        waitForChromeToExit(
            operation,
            reopenChrome: true,
            attemptsRemaining: 80
        )
    }

    private func waitForChromeToExit(
        _ operation: ChromeDNSOperation,
        reopenChrome: Bool,
        attemptsRemaining: Int
    ) {
        guard chromeDNSManager.isChromeRunning() else {
            performChromeDNSOperation(operation, reopenChrome: reopenChrome)
            return
        }
        guard attemptsRemaining > 0 else {
            chromeDNSState = .error(ChromeDNSIntegrationError.chromeDidNotQuit.localizedDescription)
            chromeDNSMessage = ChromeDNSIntegrationError.chromeDidNotQuit.localizedDescription
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForChromeToExit(
                operation,
                reopenChrome: reopenChrome,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func performChromeDNSOperation(
        _ operation: ChromeDNSOperation,
        reopenChrome: Bool
    ) {
        chromeDNSState = .configuring
        chromeDNSMessage = operation == .configure
            ? "Configuring Chrome DNS integration..."
            : "Removing Chrome DNS integration..."

        do {
            switch operation {
            case .configure:
                try chromeDNSManager.configure()
                chromeDNSState = .configured
                chromeDNSCanRemove = chromeDNSManager.hasRestorableIntegration()
                chromeDNSMessage = Self.chromeDNSSafetyMessage
            case .remove:
                switch try chromeDNSManager.removeIntegration() {
                case .removed:
                    refreshChromeDNSState()
                    chromeDNSMessage = "The original Chrome DNS preferences were restored."
                case .settingsChangedExternally:
                    chromeDNSState = .modifiedExternally
                    chromeDNSCanRemove = false
                    chromeDNSMessage = "Chrome DNS settings changed externally. SeparateProxy did not overwrite them."
                case .notConfigured:
                    refreshChromeDNSState()
                    chromeDNSMessage = "No SeparateProxy Chrome DNS integration record was found."
                }
            }

            if reopenChrome {
                try chromeDNSManager.reopenChrome()
            }
        } catch {
            chromeDNSState = .error(error.localizedDescription)
            chromeDNSMessage = error.localizedDescription
        }
    }

    private func refreshChromeDNSState() {
        chromeDNSState = chromeDNSManager.integrationState()
        chromeDNSCanRemove = chromeDNSManager.hasRestorableIntegration()
        switch chromeDNSState {
        case .notConfigured:
            chromeDNSMessage = "Chrome DNS integration is not configured."
        case .chromeRunning:
            chromeDNSMessage = "Quit Google Chrome to configure its DNS integration safely."
        case .readyToConfigure:
            chromeDNSMessage = "Chrome is ready for one-time DNS integration setup."
        case .configuring:
            break
        case .configured:
            chromeDNSMessage = Self.chromeDNSSafetyMessage
        case .modifiedExternally:
            chromeDNSMessage = "Chrome DNS settings changed externally. SeparateProxy will not overwrite them."
        case let .unsupported(reason), let .error(reason):
            chromeDNSMessage = reason
        }
    }

    private static let chromeDNSSafetyMessage = "Chrome prefers Cloudflare DoH. If DoH is unavailable in automatic mode, Chrome may fall back to the macOS system resolver."

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
