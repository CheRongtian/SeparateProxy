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
    @Published var codexIsSelected: Bool {
        didSet {
            UserDefaults.standard.set(codexIsSelected, forKey: Self.codexSelectionKey)
            if codexIsSelected {
                vsCodeBundleURL = ApplicationDiscovery.findVisualStudioCodeBundleURL()
            } else {
                vsCodeBundleURL = nil
            }
        }
    }
    @Published var gitIsSelected: Bool {
        didSet {
            UserDefaults.standard.set(gitIsSelected, forKey: Self.gitSelectionKey)
        }
    }
    @Published var dockerHubIsSelected: Bool {
        didSet {
            UserDefaults.standard.set(
                dockerHubIsSelected,
                forKey: Self.dockerHubSelectionKey
            )
        }
    }
    @Published var proxyWebsiteInput = ""
    @Published private(set) var proxyWebsiteHostnames: [String]
    @Published var showChromeECHConfirmation = false
    @Published private(set) var keyIsSaved = false
    @Published private(set) var chrome: DiscoveredApplication?
    @Published private(set) var codexTargetState: CodexTargetState = .notInstalled
    @Published private(set) var gitTargetState: GitTargetState = .notFound
    @Published private(set) var dockerHubTargetState: DockerHubTargetState = .notFound
    @Published private(set) var vsCodeBundleURL: URL?
    @Published private(set) var state: ProxyState = .helperNotInstalled {
        didSet {
            synchronizeTrafficPolling()
        }
    }
    @Published private(set) var message = "Helper setup is required."
    @Published private(set) var trafficDisplayState: TrafficDisplayState = .sessionUnavailable
    @Published private(set) var chromeDNSState: ChromeDNSIntegrationState = .notConfigured
    @Published private(set) var chromeDNSMessage = "Chrome DNS integration has not been checked."
    @Published private(set) var chromeDNSCanRemove = false
    @Published private(set) var chromeECHState: ChromeECHRequirementState = .notConfigured
    @Published private(set) var chromeECHMessage = "Chrome ECH integration has not been checked."
    @Published private(set) var chromeECHCanRemove = false

    private static let chromeSelectionKey = "chrome-is-selected"
    private static let codexSelectionKey = "codex-is-selected"
    private static let gitSelectionKey = "git-is-selected"
    private static let dockerHubSelectionKey = "docker-is-selected"
    private static let proxyWebsiteHostnamesKey = "proxy-website-hostnames"
    private let keychain = KeychainStore()
    private let helperClient = HelperClient()
    private let chromeDNSManager = ChromeDNSManager()
    private let chromeECHManager = ChromeECHManager()
    private let helperService = SMAppService.daemon(
        plistName: SeparateProxyIdentifiers.helperPlist
    )
    private var trafficPresentation = TrafficPresentationModel()
    private var trafficPollingTask: Task<Void, Never>?
    private var trafficQueryIsInFlight = false
    private var trafficPollingGeneration: UInt64 = 0
    private var trafficPresentationIsVisible = false

    init() {
        if UserDefaults.standard.object(forKey: Self.chromeSelectionKey) == nil {
            chromeIsSelected = true
        } else {
            chromeIsSelected = UserDefaults.standard.bool(forKey: Self.chromeSelectionKey)
        }
        codexIsSelected = UserDefaults.standard.bool(forKey: Self.codexSelectionKey)
        gitIsSelected = UserDefaults.standard.bool(forKey: Self.gitSelectionKey)
        dockerHubIsSelected = UserDefaults.standard.bool(forKey: Self.dockerHubSelectionKey)
        let storedHostnames = UserDefaults.standard.stringArray(
            forKey: Self.proxyWebsiteHostnamesKey
        ) ?? []
        proxyWebsiteHostnames = (
            try? ProxyWebsiteHostnameNormalizer.validateNormalizedList(storedHostnames)
        ) ?? []
        refreshLocalState()
    }

    var canStart: Bool {
        let canRetry = state == .stopped || state == .error
        let hasSelection = chromeIsSelected
            || codexIsSelected
            || gitIsSelected
            || dockerHubIsSelected
        let selectedTargetsAreAvailable = (!chromeIsSelected || chrome != nil)
            && (!codexIsSelected || (codexTargetState.canSelect && vsCodeBundleURL != nil))
            && (!gitIsSelected || gitTargetState.canSelect)
            && (!dockerHubIsSelected || dockerHubTargetState.canSelect)
        return canRetry
            && helperService.status == .enabled
            && keyIsSaved
            && hasSelection
            && selectedTargetsAreAvailable
    }

    var canStop: Bool {
        state == .running
    }

    var trafficIsUnavailable: Bool {
        trafficDisplayState == .accountingUnavailable
    }

    var proxyUploadSpeedLabel: String {
        formattedTrafficRate(\.proxyUploadBytesPerSecond)
    }

    var proxyDownloadSpeedLabel: String {
        formattedTrafficRate(\.proxyDownloadBytesPerSecond)
    }

    var directUploadSpeedLabel: String {
        formattedTrafficRate(\.directUploadBytesPerSecond)
    }

    var directDownloadSpeedLabel: String {
        formattedTrafficRate(\.directDownloadBytesPerSecond)
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

    var chromeLegacyDNSStatusLabel: String? {
        if chromeDNSCanRemove {
            switch chromeDNSState {
            case .configured, .chromeRunning, .readyToConfigure, .configuring:
                return "Legacy DNS: Pending Migration"
            case .modifiedExternally:
                return "Legacy DNS: Changed Externally"
            case .unsupported, .error:
                return "Legacy DNS: Error"
            case .notConfigured:
                return nil
            }
        }
        if chromeDNSState == .modifiedExternally {
            return "Legacy DNS: Changed Externally"
        }
        return nil
    }

    var chromeECHStateLabel: String {
        switch chromeECHState {
        case .notConfigured:
            return "Not Configured"
        case .chromeRunning:
            return "Chrome Is Running"
        case .configured:
            return "Disabled"
        case .satisfiedByManagedPolicy:
            return "Disabled by Policy"
        case .modifiedExternally:
            return "Changed Externally"
        case .managedEnabled:
            return "Enabled by Policy"
        case .unsupported:
            return "Unavailable"
        case .error:
            return "Error"
        }
    }

    var codexTargetDetail: String {
        if codexIsSelected,
           codexTargetState.canSelect,
           vsCodeBundleURL == nil {
            return "Visual Studio Code was not found."
        }
        return codexTargetState.detail
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

    func trafficPresentationAppeared() {
        trafficPresentationIsVisible = true
        synchronizeTrafficPolling()
    }

    func trafficPresentationDisappeared() {
        trafficPresentationIsVisible = false
        stopTrafficPolling()
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

    func addProxyWebsite() {
        do {
            proxyWebsiteHostnames = try ProxyWebsiteHostnameNormalizer.adding(
                proxyWebsiteInput,
                to: proxyWebsiteHostnames
            )
            UserDefaults.standard.set(
                proxyWebsiteHostnames,
                forKey: Self.proxyWebsiteHostnamesKey
            )
            proxyWebsiteInput = ""
            message = state == .running
                ? "Proxy Website changes will apply the next time the proxy starts."
                : "The Proxy Websites list was updated."
            refreshChromeECHState()
        } catch {
            message = error.localizedDescription
        }
    }

    func removeProxyWebsite(_ hostname: String) {
        proxyWebsiteHostnames.removeAll { $0 == hostname }
        UserDefaults.standard.set(
            proxyWebsiteHostnames,
            forKey: Self.proxyWebsiteHostnamesKey
        )
        message = state == .running
            ? "Proxy Website changes will apply the next time the proxy starts."
            : "The Proxy Websites list was updated."
        refreshChromeECHState()
    }

    func confirmChromeECHConfigurationAndStart() {
        showChromeECHConfirmation = false
        let chromeWasRunning = chromeECHManager.isChromeRunning()
        guard chromeWasRunning else {
            configureChromeECHAndStart(reopenChrome: false)
            return
        }
        state = .starting
        message = "Waiting for Google Chrome to quit safely..."
        guard chromeECHManager.requestChromeTermination() else {
            state = .error
            message = ChromeDNSIntegrationError.chromeDidNotQuit.localizedDescription
            return
        }
        waitForChromeECHExit(
            operation: .configureAndStart,
            reopenChrome: true,
            attemptsRemaining: 80
        )
    }

    func removeChromeECHIntegration() {
        guard state != .running, state != .starting, state != .stopping else {
            message = "Stop the proxy before restoring the Chrome ECH setting."
            return
        }
        if chromeECHState == .modifiedExternally {
            performChromeECHRemoval(reopenChrome: false)
            return
        }
        let chromeWasRunning = chromeECHManager.isChromeRunning()
        guard chromeWasRunning else {
            performChromeECHRemoval(reopenChrome: false)
            return
        }
        message = "Waiting for Google Chrome to quit safely..."
        guard chromeECHManager.requestChromeTermination() else {
            state = .error
            message = ChromeDNSIntegrationError.chromeDidNotQuit.localizedDescription
            return
        }
        waitForChromeECHExit(
            operation: .remove,
            reopenChrome: true,
            attemptsRemaining: 80
        )
    }

    func start() {
        guard chromeIsSelected || codexIsSelected || gitIsSelected || dockerHubIsSelected else {
            state = .error
            message = SingBoxConfigurationError.noTargetsSelected.localizedDescription
            return
        }
        if chromeIsSelected, chrome == nil {
            state = .error
            message = "Google Chrome is unavailable."
            return
        }
        if codexIsSelected, !codexTargetState.canSelect {
            state = .error
            message = "The OpenAI Codex VS Code extension is unavailable."
            return
        }
        if codexIsSelected {
            vsCodeBundleURL = ApplicationDiscovery.findVisualStudioCodeBundleURL()
            guard vsCodeBundleURL != nil else {
                state = .error
                message = "Visual Studio Code is unavailable."
                return
            }
        }
        if gitIsSelected, !gitTargetState.canSelect {
            state = .error
            message = "Apple/Xcode Git HTTPS support is unavailable."
            return
        }
        if dockerHubIsSelected, !dockerHubTargetState.canSelect {
            state = .error
            message = "Docker Hub support is unavailable."
            return
        }

        if chromeIsSelected, !proxyWebsiteHostnames.isEmpty {
            do {
                guard try chromeECHManager.isRequirementSatisfied() else {
                    showChromeECHConfirmation = true
                    message = "Proxy Websites requires one-time Chrome ECH configuration."
                    return
                }
            } catch {
                state = .error
                message = error.localizedDescription
                refreshChromeECHState()
                return
            }
            migrateLegacyChromeDNSAndStart(reopenChrome: false)
            return
        }

        startProxy(reopenChromeAfterCompletion: false)
    }

    private func startProxy(reopenChromeAfterCompletion: Bool) {

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
                chromeBundlePath: chromeIsSelected ? chrome?.bundleURL.path ?? "" : "",
                codexEnabled: codexIsSelected,
                gitEnabled: gitIsSelected,
                dockerEnabled: dockerHubIsSelected,
                vsCodeBundlePath: codexIsSelected ? vsCodeBundleURL?.path ?? "" : "",
                proxyWebsiteHostnames: chromeIsSelected ? proxyWebsiteHostnames : []
            ) { [weak self] result in
                Task { @MainActor in
                    self?.applyHelperResult(result)
                    if reopenChromeAfterCompletion {
                        do {
                            try self?.chromeECHManager.reopenChrome()
                        } catch {
                            self?.message += " Chrome could not be reopened: \(error.localizedDescription)"
                        }
                    }
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
        codexTargetState = CodexTargetDiscovery.discover()
        gitTargetState = GitTargetDiscovery.discover()
        dockerHubTargetState = DockerHubTargetDiscovery.discover()
        if !codexTargetState.canSelect {
            codexIsSelected = false
        }
        if !gitTargetState.canSelect {
            gitIsSelected = false
        }
        if !dockerHubTargetState.canSelect {
            dockerHubIsSelected = false
        }
        if codexIsSelected, codexTargetState.canSelect {
            vsCodeBundleURL = ApplicationDiscovery.findVisualStudioCodeBundleURL()
        } else {
            vsCodeBundleURL = nil
        }
        refreshChromeDNSState()
        refreshChromeECHState()
        refreshHelperState()
    }

    private enum ChromeECHOperation {
        case configureAndStart
        case migrateDNSAndStart
        case remove
    }

    private func waitForChromeECHExit(
        operation: ChromeECHOperation,
        reopenChrome: Bool,
        attemptsRemaining: Int
    ) {
        guard chromeECHManager.isChromeRunning() else {
            switch operation {
            case .configureAndStart:
                configureChromeECHAndStart(reopenChrome: reopenChrome)
            case .migrateDNSAndStart:
                migrateLegacyChromeDNSAndStart(reopenChrome: reopenChrome)
            case .remove:
                performChromeECHRemoval(reopenChrome: reopenChrome)
            }
            return
        }
        guard attemptsRemaining > 0 else {
            state = .error
            message = ChromeDNSIntegrationError.chromeDidNotQuit.localizedDescription
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForChromeECHExit(
                operation: operation,
                reopenChrome: reopenChrome,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func configureChromeECHAndStart(reopenChrome: Bool) {
        state = .starting
        message = "Configuring Chrome Website Routing..."
        do {
            _ = try chromeDNSManager.migrateLegacyIntegrationForWebsiteRouting()
            refreshChromeDNSState()
            try chromeECHManager.configure()
            refreshChromeECHState()
            startProxy(reopenChromeAfterCompletion: reopenChrome)
        } catch {
            state = .error
            message = "Chrome Website Routing setup failed: \(error.localizedDescription)"
            refreshChromeDNSState()
            refreshChromeECHState()
            if reopenChrome {
                try? chromeECHManager.reopenChrome()
            }
        }
    }

    private func migrateLegacyChromeDNSAndStart(reopenChrome: Bool) {
        state = .starting
        message = "Checking legacy Chrome DNS integration..."
        do {
            _ = try chromeDNSManager.migrateLegacyIntegrationForWebsiteRouting()
            refreshChromeDNSState()
            startProxy(reopenChromeAfterCompletion: reopenChrome)
        } catch ChromeDNSIntegrationError.chromeRunning {
            message = "Waiting for Google Chrome to quit safely for legacy DNS migration..."
            guard chromeDNSManager.requestChromeTermination() else {
                state = .error
                message = ChromeDNSIntegrationError.chromeDidNotQuit.localizedDescription
                return
            }
            waitForChromeECHExit(
                operation: .migrateDNSAndStart,
                reopenChrome: true,
                attemptsRemaining: 80
            )
        } catch {
            state = .error
            message = "Chrome DNS migration failed: \(error.localizedDescription)"
            refreshChromeDNSState()
            if reopenChrome {
                try? chromeDNSManager.reopenChrome()
            }
        }
    }

    private func performChromeECHRemoval(reopenChrome: Bool) {
        do {
            switch try chromeECHManager.removeIntegration() {
            case .removed:
                message = "The original Chrome ECH preference was restored."
            case .settingsChangedExternally:
                message = "Chrome ECH settings changed externally. SeparateProxy did not overwrite them."
            case .notConfigured:
                message = "No SeparateProxy Chrome ECH integration record was found."
            }
            refreshChromeECHState()
            if reopenChrome {
                try chromeECHManager.reopenChrome()
            }
        } catch {
            state = .error
            message = error.localizedDescription
            refreshChromeECHState()
            if reopenChrome {
                try? chromeECHManager.reopenChrome()
            }
        }
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
            chromeDNSMessage = "No legacy SeparateProxy DNS configuration requires migration."
        case .chromeRunning:
            chromeDNSMessage = chromeDNSCanRemove
                ? "Legacy SeparateProxy DNS configuration will be restored on the next Website Routing Start."
                : "No legacy SeparateProxy DNS configuration requires migration."
        case .readyToConfigure:
            chromeDNSMessage = "No legacy SeparateProxy DNS configuration requires migration."
        case .configuring:
            break
        case .configured:
            chromeDNSMessage = "Legacy SeparateProxy DNS configuration will be restored on the next Website Routing Start."
        case .modifiedExternally:
            chromeDNSMessage = "Legacy Chrome DNS settings changed externally. SeparateProxy will not overwrite them."
        case let .unsupported(reason), let .error(reason):
            chromeDNSMessage = reason
        }
    }

    private func refreshChromeECHState() {
        chromeECHState = chromeECHManager.requirementState()
        chromeECHCanRemove = chromeECHManager.hasRestorableIntegration()
        switch chromeECHState {
        case .notConfigured:
            chromeECHMessage = "Encrypted ClientHello must be disabled before Proxy Websites can start."
        case .chromeRunning:
            chromeECHMessage = "Chrome must quit before SeparateProxy can disable Encrypted ClientHello."
        case .configured:
            chromeECHMessage = "Encrypted ClientHello is disabled for Chrome Website Routing."
        case .satisfiedByManagedPolicy:
            chromeECHMessage = "A managed Chrome policy disables Encrypted ClientHello."
        case .modifiedExternally:
            chromeECHMessage = "Chrome ECH settings changed externally. SeparateProxy will not overwrite them."
        case .managedEnabled:
            chromeECHMessage = ChromeECHIntegrationError.managedPolicyEnablesECH.localizedDescription
        case let .unsupported(reason), let .error(reason):
            chromeECHMessage = reason
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

    private func synchronizeTrafficPolling() {
        if state == .running, trafficPresentationIsVisible {
            startTrafficPolling()
        } else {
            stopTrafficPolling()
        }
    }

    private func startTrafficPolling() {
        guard trafficPresentation.beginPolling() else {
            return
        }
        trafficDisplayState = trafficPresentation.displayState
        trafficPollingGeneration &+= 1
        let generation = trafficPollingGeneration
        trafficPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                self.pollTrafficCounters(generation: generation)
                do {
                    try await Task.sleep(for: TrafficAccountingConstants.pollingInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func stopTrafficPolling() {
        trafficPollingGeneration &+= 1
        trafficPollingTask?.cancel()
        trafficPollingTask = nil
        trafficQueryIsInFlight = false
        trafficPresentation.stopPolling()
        trafficDisplayState = trafficPresentation.displayState
    }

    private func pollTrafficCounters(generation: UInt64) {
        guard !trafficQueryIsInFlight else {
            return
        }
        trafficQueryIsInFlight = true
        helperClient.trafficCounters { [weak self] result in
            Task { @MainActor in
                guard let self,
                      self.trafficPollingGeneration == generation,
                      self.state == .running,
                      self.trafficPresentationIsVisible else {
                    return
                }
                self.trafficQueryIsInFlight = false
                switch result {
                case let .success(snapshot):
                    self.trafficPresentation.update(snapshot)
                case .failure:
                    self.trafficPresentation.markAccountingUnavailable()
                }
                self.trafficDisplayState = self.trafficPresentation.displayState
            }
        }
    }

    private func formattedTrafficRate(
        _ keyPath: KeyPath<TrafficRates, Double>
    ) -> String {
        guard case let .active(rates) = trafficDisplayState else {
            return "—"
        }
        return TrafficRateFormatter.string(from: rates[keyPath: keyPath])
    }
}
