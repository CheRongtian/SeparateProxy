import AppKit
import SeparateProxyCore
import SwiftUI

@MainActor
protocol ProxyViewModeling: ObservableObject {
    var accessKeyInput: String { get set }
    var chromeIsSelected: Bool { get set }
    var googleWebsiteRoutingIsEnabled: Bool { get set }
    var codexIsSelected: Bool { get set }
    var gitIsSelected: Bool { get set }
    var dockerHubIsSelected: Bool { get set }
    var kubernetesIsSelected: Bool { get set }
    var homebrewIsSelected: Bool { get set }
    var proxyWebsiteInput: String { get set }
    var proxyWebsiteHostnames: [String] { get }
    var showChromeECHConfirmation: Bool { get set }
    var keyIsSaved: Bool { get }
    var chrome: DiscoveredApplication? { get }
    var codexTargetState: CodexTargetState { get }
    var gitTargetState: GitTargetState { get }
    var dockerHubTargetState: DockerHubTargetState { get }
    var kubernetesTargetState: DockerHubTargetState { get }
    var homebrewTargetState: HomebrewTargetState { get }
    var state: ProxyState { get }
    var message: String { get }
    var chromeDNSState: ChromeDNSIntegrationState { get }
    var chromeDNSMessage: String { get }
    var chromeDNSCanRemove: Bool { get }
    var chromeECHState: ChromeECHRequirementState { get }
    var chromeECHMessage: String { get }
    var chromeECHCanRemove: Bool { get }
    var canStart: Bool { get }
    var canStop: Bool { get }
    var trafficIsUnavailable: Bool { get }
    var proxyUploadSpeedLabel: String { get }
    var proxyDownloadSpeedLabel: String { get }
    var directUploadSpeedLabel: String { get }
    var directDownloadSpeedLabel: String { get }
    var stateLabel: String { get }
    var chromeLegacyDNSStatusLabel: String? { get }
    var chromeECHStateLabel: String { get }
    var codexTargetDetail: String { get }

    func saveAccessKey()
    func deleteAccessKey()
    func enableHelper()
    func openHelperSettings()
    func refresh()
    func trafficPresentationAppeared()
    func trafficPresentationDisappeared()
    func removeChromeDNSIntegration()
    func addProxyWebsite()
    func removeProxyWebsite(_ hostname: String)
    func confirmChromeECHConfigurationAndStart()
    func removeChromeECHIntegration()
    func start()
    func stop()
}

extension ProxyViewModel: ProxyViewModeling {}

struct ContentView<ViewModel: ProxyViewModeling>: View {
    @StateObject private var viewModel: ViewModel
    @State private var isEditingAccessKey = false
    @State private var isWebsiteRoutingExpanded: Bool

    init(
        viewModel: ViewModel,
        initiallyExpandsWebsiteRouting: Bool = false
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _isWebsiteRoutingExpanded = State(
            initialValue: initiallyExpandsWebsiteRouting
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            HStack(alignment: .top, spacing: 16) {
                configurationColumn
                Divider()
                sessionPanel
                    .frame(width: 264)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(24)
        .frame(
            minWidth: 800,
            idealWidth: 840,
            minHeight: 600,
            idealHeight: 660
        )
        .onAppear {
            viewModel.trafficPresentationAppeared()
        }
        .onDisappear {
            viewModel.trafficPresentationDisappeared()
        }
        .alert(
            "Disable Chrome ECH for Website Routing?",
            isPresented: $viewModel.showChromeECHConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Quit and Configure Chrome") {
                viewModel.confirmChromeECHConfigurationAndStart()
            }
        } message: {
            Text(
                "Website Routing needs to see TLS and QUIC hostnames. SeparateProxy will disable Encrypted ClientHello for all Chrome sites. HTTPS content remains encrypted, while hostnames become more visible to the network. The original setting is saved and can be restored later."
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SeparateProxy")
                .font(.title.bold())
            Text("Route selected Chrome websites and developer tools through Outline.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var configurationColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONFIGURATION")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    keySection
                    applicationSection
                    if viewModel.chrome != nil {
                        websiteRoutingSection
                    }
                    developerToolsSection
                }
                .padding(.trailing, 8)
                .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sessionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SESSION")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                statusSection
                Divider()
                trafficSection
                Spacer(minLength: 16)
                controls
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SurfaceBackground())
        }
    }

    private var keySection: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Outline Access Key")
                        .font(.headline)
                    Spacer()
                    StatusBadge(
                        title: viewModel.keyIsSaved ? "Saved in Keychain" : "Not Saved",
                        systemImage: viewModel.keyIsSaved
                            ? "checkmark.shield.fill"
                            : "exclamationmark.triangle.fill",
                        color: viewModel.keyIsSaved ? .green : .orange
                    )
                }

                if viewModel.keyIsSaved, !isEditingAccessKey {
                    HStack {
                        Button("Replace Key") {
                            isEditingAccessKey = true
                        }

                        Spacer()

                        Button("Remove Key", role: .destructive) {
                            isEditingAccessKey = false
                            viewModel.deleteAccessKey()
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    SecureField(
                        viewModel.keyIsSaved
                            ? "Enter replacement ss:// key"
                            : "Enter ss:// key",
                        text: $viewModel.accessKeyInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(
                        viewModel.keyIsSaved
                            ? "Replacement Outline Access Key"
                            : "Outline Access Key"
                    )

                    HStack {
                        Button(viewModel.keyIsSaved ? "Save" : "Save Key") {
                            viewModel.saveAccessKey()
                            if viewModel.keyIsSaved {
                                isEditingAccessKey = false
                            }
                        }
                        .disabled(viewModel.accessKeyInput.isEmpty)

                        if viewModel.keyIsSaved {
                            Button("Cancel") {
                                viewModel.accessKeyInput = ""
                                isEditingAccessKey = false
                            }
                        }
                    }
                }
            }
        }
    }

    private var applicationSection: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Applications")
                    .font(.headline)

                if let chrome = viewModel.chrome {
                    HStack(alignment: .center, spacing: 12) {
                        Image(nsImage: chrome.icon)
                            .resizable()
                            .frame(width: 32, height: 32)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(chrome.name)
                                .font(.body.weight(.medium))
                            Text(chrome.bundleURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(chrome.bundleURL.path)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        chromeIntegrationMenu

                        Toggle("Google Chrome", isOn: $viewModel.chromeIsSelected)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Google Chrome")
                    }
                } else {
                    Label("Google Chrome was not found.", systemImage: "app.dashed")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var websiteRoutingSection: some View {
        SectionSurface {
            DisclosureGroup(isExpanded: $isWebsiteRoutingExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("ECH compatibility:")
                            Text(viewModel.chromeECHStateLabel)
                                .foregroundStyle(chromeECHStatusColor)
                        }
                        .help(viewModel.chromeECHMessage)

                        if let legacyDNSStatus = viewModel.chromeLegacyDNSStatusLabel {
                            Text(legacyDNSStatus)
                                .foregroundStyle(chromeDNSStatusColor)
                                .help(viewModel.chromeDNSMessage)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Google")
                                .font(.body.weight(.medium))
                            Text("Search, Drive, Account / OAuth, and Gemini")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Toggle(
                            "Google Website Routing",
                            isOn: $viewModel.googleWebsiteRoutingIsEnabled
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Google Website Routing")
                    }

                    Divider()

                    HStack {
                        Text("Custom Websites")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(
                            "\(viewModel.proxyWebsiteHostnames.count) / \(ProxyWebsiteHostnameNormalizer.maximumCustomHostnameCount)"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "https://example.com/path",
                            text: $viewModel.proxyWebsiteInput
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Custom Website URL")
                        .onSubmit {
                            viewModel.addProxyWebsite()
                        }

                        Button("Add") {
                            viewModel.addProxyWebsite()
                        }
                        .disabled(viewModel.proxyWebsiteInput.isEmpty)
                    }

                    if viewModel.proxyWebsiteHostnames.isEmpty {
                        Text("No custom websites are configured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.proxyWebsiteHostnames, id: \.self) { hostname in
                                HStack(spacing: 8) {
                                    Text("https://\(hostname)")
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                        .help("https://\(hostname)")
                                    Spacer(minLength: 8)
                                    Button(role: .destructive) {
                                        viewModel.removeProxyWebsite(hostname)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .frame(width: 20, height: 20)
                                    }
                                    .buttonStyle(.borderless)
                                    .frame(minWidth: 28, minHeight: 28)
                                    .contentShape(Rectangle())
                                    .help("Remove \(hostname)")
                                    .accessibilityLabel("Remove \(hostname)")
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Exact hostnames only.")
                        Text("Changes made while running apply on the next Start.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } label: {
                Text("Chrome Website Routing")
                    .font(.headline)
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Status")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Refresh Status")
                .accessibilityLabel("Refresh Status")
            }

            Group {
                switch viewModel.state {
                case .starting, .stopping:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.stateLabel)
                            .font(.title3.weight(.semibold))
                    }
                default:
                    Label(viewModel.stateLabel, systemImage: sessionStatusIcon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(sessionStatusColor)
                }
            }

            Text(viewModel.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, alignment: .topLeading)
        }
    }

    private var developerToolsSection: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Developer Tools")
                    .font(.headline)

                TargetRow(
                    title: "Codex",
                    subtitle: viewModel.codexTargetDetail,
                    systemImage: "terminal",
                    status: viewModel.codexTargetState.label,
                    statusSystemImage: codexStatusIcon,
                    statusColor: codexStatusColor,
                    isOn: $viewModel.codexIsSelected,
                    isEnabled: viewModel.codexTargetState.canSelect
                )

                Divider()

                TargetRow(
                    title: "Git",
                    subtitle: viewModel.gitTargetState.detail,
                    systemImage: "arrow.triangle.branch",
                    status: viewModel.gitTargetState.label,
                    statusSystemImage: gitStatusIcon,
                    statusColor: gitStatusColor,
                    isOn: $viewModel.gitIsSelected,
                    isEnabled: viewModel.gitTargetState.canSelect
                )

                Divider()

                TargetRow(
                    title: "Docker Hub",
                    subtitle: viewModel.dockerHubTargetState.detail,
                    tertiaryDetail: viewModel.dockerHubIsSelected
                        ? "Browser sign-in uses Chrome Website Routing."
                        : nil,
                    systemImage: "shippingbox",
                    status: viewModel.dockerHubTargetState.label,
                    statusSystemImage: dockerHubStatusIcon,
                    statusColor: dockerHubStatusColor,
                    isOn: $viewModel.dockerHubIsSelected,
                    isEnabled: viewModel.dockerHubTargetState.canSelect
                )

                Divider()

                TargetRow(
                    title: "Kubernetes",
                    subtitle: "Official registry images",
                    systemImage: "circle.grid.3x3.fill",
                    status: viewModel.kubernetesTargetState.label,
                    statusSystemImage: kubernetesStatusIcon,
                    statusColor: kubernetesStatusColor,
                    isOn: $viewModel.kubernetesIsSelected,
                    isEnabled: viewModel.kubernetesTargetState.canSelect
                )

                Divider()

                TargetRow(
                    title: "Homebrew",
                    subtitle: viewModel.homebrewTargetState.detail,
                    systemImage: "archivebox",
                    status: viewModel.homebrewTargetState.label,
                    statusSystemImage: homebrewStatusIcon,
                    statusColor: homebrewStatusColor,
                    isOn: $viewModel.homebrewIsSelected,
                    isEnabled: viewModel.homebrewTargetState.canSelect
                )
            }
        }
    }

    private var trafficSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Traffic")
                    .font(.headline)
                Spacer()
                if viewModel.trafficIsUnavailable {
                    Label("Unavailable", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TrafficGrid(
                proxyUpload: viewModel.proxyUploadSpeedLabel,
                proxyDownload: viewModel.proxyDownloadSpeedLabel,
                directUpload: viewModel.directUploadSpeedLabel,
                directDownload: viewModel.directDownloadSpeedLabel
            )
        }
    }

    private var chromeIntegrationMenu: some View {
        Menu {
            if let legacyDNSStatus = viewModel.chromeLegacyDNSStatusLabel {
                Text(legacyDNSStatus)
                if viewModel.chromeDNSCanRemove {
                    Button("Restore Original DNS Settings", role: .destructive) {
                        viewModel.removeChromeDNSIntegration()
                    }
                }
                Divider()
            }

            Text("Website Routing ECH: \(viewModel.chromeECHStateLabel)")
            if viewModel.chromeECHCanRemove {
                Button("Restore Original ECH Setting", role: .destructive) {
                    viewModel.removeChromeECHIntegration()
                }
                .disabled(viewModel.state == .running || viewModel.state == .starting)
            }

            Divider()
            Button("Refresh Chrome Integration Status") {
                viewModel.refresh()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Chrome Integration Actions")
        .accessibilityLabel("Chrome Integration Actions")
    }

    private var chromeDNSStatusColor: Color {
        switch viewModel.chromeDNSState {
        case .configured, .configuring, .modifiedExternally, .unsupported, .error:
            return .orange
        default:
            return .secondary
        }
    }

    private var chromeECHStatusColor: Color {
        switch viewModel.chromeECHState {
        case .configured, .satisfiedByManagedPolicy:
            return .green
        case .modifiedExternally, .managedEnabled, .unsupported, .error:
            return .orange
        default:
            return .secondary
        }
    }

    private var codexStatusColor: Color {
        switch viewModel.codexTargetState {
        case .installed:
            return .green
        case .notInstalled, .incompleteInstallation, .unsupportedInstallation:
            return .orange
        }
    }

    private var codexStatusIcon: String {
        switch viewModel.codexTargetState {
        case .installed:
            return "checkmark.circle.fill"
        case .notInstalled:
            return "minus.circle"
        case .incompleteInstallation, .unsupportedInstallation:
            return "exclamationmark.triangle.fill"
        }
    }

    private var gitStatusColor: Color {
        switch viewModel.gitTargetState {
        case .installed:
            return .green
        case .notFound, .unsupported:
            return .orange
        }
    }

    private var gitStatusIcon: String {
        switch viewModel.gitTargetState {
        case .installed:
            return "checkmark.circle.fill"
        case .notFound:
            return "minus.circle"
        case .unsupported:
            return "exclamationmark.triangle.fill"
        }
    }

    private var dockerHubStatusColor: Color {
        switch viewModel.dockerHubTargetState {
        case .installed:
            return .green
        case .notFound, .unsupported:
            return .orange
        }
    }

    private var dockerHubStatusIcon: String {
        switch viewModel.dockerHubTargetState {
        case .installed:
            return "checkmark.circle.fill"
        case .notFound:
            return "minus.circle"
        case .unsupported:
            return "exclamationmark.triangle.fill"
        }
    }

    private var kubernetesStatusColor: Color {
        switch viewModel.kubernetesTargetState {
        case .installed:
            return .green
        case .notFound, .unsupported:
            return .orange
        }
    }

    private var kubernetesStatusIcon: String {
        switch viewModel.kubernetesTargetState {
        case .installed:
            return "checkmark.circle.fill"
        case .notFound:
            return "minus.circle"
        case .unsupported:
            return "exclamationmark.triangle.fill"
        }
    }

    private var homebrewStatusColor: Color {
        switch viewModel.homebrewTargetState {
        case .installed:
            return .green
        case .notFound:
            return .orange
        }
    }

    private var homebrewStatusIcon: String {
        switch viewModel.homebrewTargetState {
        case .installed:
            return "checkmark.circle.fill"
        case .notFound:
            return "minus.circle"
        }
    }

    private var sessionStatusIcon: String {
        switch viewModel.state {
        case .running:
            return "circle.fill"
        case .stopped:
            return "circle"
        case .helperNotInstalled, .approvalRequired:
            return "exclamationmark.triangle.fill"
        case .error:
            return "exclamationmark.octagon.fill"
        case .starting, .stopping:
            return "clock"
        }
    }

    private var sessionStatusColor: Color {
        switch viewModel.state {
        case .running:
            return .green
        case .helperNotInstalled, .approvalRequired:
            return .orange
        case .error:
            return .red
        case .stopped, .starting, .stopping:
            return .secondary
        }
    }

    private var controls: some View {
        Group {
            switch viewModel.state {
            case .helperNotInstalled:
                Button {
                    viewModel.enableHelper()
                } label: {
                    Text("Enable Helper")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .approvalRequired:
                Button {
                    viewModel.openHelperSettings()
                } label: {
                    Text("Open System Settings")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .running:
                Button {
                    viewModel.stop()
                } label: {
                    Text("Stop Proxy")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStop)
            case .starting, .stopping:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(viewModel.stateLabel)
                }
                .frame(maxWidth: .infinity)
            case .stopped, .error:
                Button {
                    viewModel.start()
                } label: {
                    Text("Start Proxy")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStart)
            }
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity, minHeight: 32)
    }
}

extension ContentView where ViewModel == ProxyViewModel {
    init() {
        self.init(viewModel: ProxyViewModel())
    }
}

private struct SectionSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SurfaceBackground())
    }
}

private struct SurfaceBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: NSColor.controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        Color(nsColor: NSColor.separatorColor).opacity(0.65),
                        lineWidth: 1
                    )
            }
    }
}

private struct StatusBadge: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct TargetRow: View {
    let title: String
    let subtitle: String
    var tertiaryDetail: String? = nil
    let systemImage: String
    let status: String
    let statusSystemImage: String
    let statusColor: Color
    @Binding var isOn: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let tertiaryDetail {
                    Text(tertiaryDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusBadge(
                title: status,
                systemImage: statusSystemImage,
                color: statusColor
            )

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!isEnabled)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 2)
        .opacity(isEnabled ? 1 : 0.68)
    }
}

private struct TrafficGrid: View {
    let proxyUpload: String
    let proxyDownload: String
    let directUpload: String
    let directDownload: String

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Color.clear
                    .frame(width: 1, height: 1)
                Text("Upload")
                Text("Download")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            GridRow {
                Text("Proxy")
                    .gridColumnAlignment(.leading)
                Label(proxyUpload, systemImage: "arrow.up")
                Label(proxyDownload, systemImage: "arrow.down")
            }

            GridRow {
                Text("Direct")
                    .gridColumnAlignment(.leading)
                Label(directUpload, systemImage: "arrow.up")
                Label(directDownload, systemImage: "arrow.down")
            }
        }
        .font(.callout.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
private enum PreviewProxyFixtures {
    static let chrome = DiscoveredApplication(
        bundleIdentifier: "com.google.Chrome",
        name: "Google Chrome",
        bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
        icon: NSImage(
            systemSymbolName: "globe",
            accessibilityDescription: "Google Chrome"
        ) ?? NSImage(size: NSSize(width: 32, height: 32))
    )

    static let codexInstalled = CodexTargetState.installed(
        CodexInstallation(
            version: "26.9.0",
            extensionRootPath: "/Preview/VSCode/extensions/openai.chatgpt",
            executablePath: "/Preview/VSCode/extensions/openai.chatgpt/bin/codex"
        )
    )

    static let gitInstalled = GitTargetState.installed(
        AppleGitInstallation(
            developerDirectoryPath: "/Preview/Xcode/Contents/Developer",
            gitExecutablePath: "/Preview/Xcode/Contents/Developer/usr/bin/git",
            httpsHelperEntryPath: "/Preview/Xcode/Contents/Developer/usr/libexec/git-core/git-remote-https",
            canonicalHTTPHelperPath: "/Preview/Xcode/Contents/Developer/usr/libexec/git-core/git-remote-http"
        )
    )

    static let dockerInstalled = DockerHubTargetState.installed(
        DockerHubInstallation(
            applicationBundlePath: "/Preview/Docker.app",
            backendExecutablePath: "/Preview/Docker.app/Contents/MacOS/com.docker.backend",
            cliExecutablePath: "/Preview/Docker.app/Contents/Resources/bin/docker"
        )
    )

    static let homebrewInstalled = HomebrewTargetState.installed(
        HomebrewInstallation(
            prefixPath: "/Preview/homebrew",
            brewExecutablePath: "/Preview/homebrew/bin/brew",
            libraryPath: "/Preview/homebrew/Library/Homebrew"
        )
    )
}

@MainActor
private final class PreviewProxyViewModel: ProxyViewModeling {
    enum Scenario {
        case running
        case stopped
        case missingTools
        case manyWebsites
    }

    @Published var accessKeyInput = ""
    @Published var chromeIsSelected = true
    @Published var googleWebsiteRoutingIsEnabled = true
    @Published var codexIsSelected = true
    @Published var gitIsSelected = true
    @Published var dockerHubIsSelected = true
    @Published var kubernetesIsSelected = true
    @Published var homebrewIsSelected = true
    @Published var proxyWebsiteInput = ""
    @Published var proxyWebsiteHostnames = ["chatgpt.com", "github.com"]
    @Published var showChromeECHConfirmation = false
    @Published var keyIsSaved = true
    @Published var chrome: DiscoveredApplication? = PreviewProxyFixtures.chrome
    @Published var codexTargetState = PreviewProxyFixtures.codexInstalled
    @Published var gitTargetState = PreviewProxyFixtures.gitInstalled
    @Published var dockerHubTargetState = PreviewProxyFixtures.dockerInstalled
    @Published var kubernetesTargetState = PreviewProxyFixtures.dockerInstalled
    @Published var homebrewTargetState = PreviewProxyFixtures.homebrewInstalled
    @Published var state: ProxyState = .running
    @Published var message = "The proxy is running. PID: 57546."
    @Published var chromeDNSState: ChromeDNSIntegrationState = .notConfigured
    @Published var chromeDNSMessage = "No legacy SeparateProxy DNS configuration requires migration."
    @Published var chromeDNSCanRemove = false
    @Published var chromeECHState: ChromeECHRequirementState = .configured
    @Published var chromeECHMessage = "Encrypted ClientHello is disabled for Chrome Website Routing."
    @Published var chromeECHCanRemove = true
    @Published var trafficIsUnavailable = false
    @Published var proxyUploadSpeedLabel = "283 B/s"
    @Published var proxyDownloadSpeedLabel = "3.7 KB/s"
    @Published var directUploadSpeedLabel = "120 B/s"
    @Published var directDownloadSpeedLabel = "800 B/s"

    init(_ scenario: Scenario) {
        switch scenario {
        case .running:
            break
        case .stopped:
            state = .stopped
            message = "The proxy is stopped."
            clearTrafficRates()
        case .missingTools:
            codexIsSelected = false
            gitIsSelected = false
            dockerHubIsSelected = false
            kubernetesIsSelected = false
            homebrewIsSelected = false
            codexTargetState = .notInstalled
            gitTargetState = .notFound
            dockerHubTargetState = .notFound
            kubernetesTargetState = .notFound
            homebrewTargetState = .notFound
            state = .stopped
            message = "Some developer tools are unavailable on this Mac."
            clearTrafficRates()
        case .manyWebsites:
            proxyWebsiteHostnames = ["chatgpt.com", "github.com"]
                + (1...24).map { "service-\($0).example.com" }
        }
    }

    var canStart: Bool {
        let canRetry = state == .stopped || state == .error
        let hasSelection = chromeIsSelected
            || codexIsSelected
            || gitIsSelected
            || dockerHubIsSelected
            || kubernetesIsSelected
            || homebrewIsSelected
        let selectedTargetsAreAvailable = (!chromeIsSelected || chrome != nil)
            && (!codexIsSelected || codexTargetState.canSelect)
            && (!gitIsSelected || gitTargetState.canSelect)
            && (!dockerHubIsSelected || dockerHubTargetState.canSelect)
            && (!kubernetesIsSelected || kubernetesTargetState.canSelect)
            && (!homebrewIsSelected || homebrewTargetState.canSelect)
        return canRetry && keyIsSaved && hasSelection && selectedTargetsAreAvailable
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

    var chromeLegacyDNSStatusLabel: String? {
        if chromeDNSCanRemove {
            return "Legacy DNS: Pending Migration"
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
        codexTargetState.detail
    }

    func saveAccessKey() {
        guard !accessKeyInput.isEmpty else {
            message = "Enter an Outline access key."
            return
        }
        accessKeyInput = ""
        keyIsSaved = true
        message = "Preview access key saved in memory."
    }

    func deleteAccessKey() {
        accessKeyInput = ""
        keyIsSaved = false
        message = "Preview access key removed from memory."
    }

    func enableHelper() {
        state = .stopped
        message = "Preview helper is ready."
    }

    func openHelperSettings() {}
    func refresh() {}
    func trafficPresentationAppeared() {}
    func trafficPresentationDisappeared() {}

    func removeChromeDNSIntegration() {
        chromeDNSState = .notConfigured
        chromeDNSCanRemove = false
        chromeDNSMessage = "Preview legacy DNS integration removed from memory."
    }

    func addProxyWebsite() {
        do {
            proxyWebsiteHostnames = try ProxyWebsiteHostnameNormalizer.adding(
                proxyWebsiteInput,
                to: proxyWebsiteHostnames
            )
            proxyWebsiteInput = ""
            message = "Preview website list updated in memory."
        } catch {
            message = error.localizedDescription
        }
    }

    func removeProxyWebsite(_ hostname: String) {
        proxyWebsiteHostnames.removeAll { $0 == hostname }
        message = "Preview website list updated in memory."
    }

    func confirmChromeECHConfigurationAndStart() {
        showChromeECHConfirmation = false
        chromeECHState = .configured
        start()
    }

    func removeChromeECHIntegration() {
        chromeECHState = .notConfigured
        chromeECHCanRemove = false
        chromeECHMessage = "Preview ECH integration removed from memory."
    }

    func start() {
        state = .running
        message = "The proxy is running. PID: 57546."
        proxyUploadSpeedLabel = "283 B/s"
        proxyDownloadSpeedLabel = "3.7 KB/s"
        directUploadSpeedLabel = "120 B/s"
        directDownloadSpeedLabel = "800 B/s"
    }

    func stop() {
        state = .stopped
        message = "The proxy is stopped."
        clearTrafficRates()
    }

    private func clearTrafficRates() {
        proxyUploadSpeedLabel = "—"
        proxyDownloadSpeedLabel = "—"
        directUploadSpeedLabel = "—"
        directDownloadSpeedLabel = "—"
    }
}

#Preview("Running") {
    ContentView(
        viewModel: PreviewProxyViewModel(.running),
        initiallyExpandsWebsiteRouting: true
    )
    .frame(width: 840, height: 660)
    .preferredColorScheme(.light)
}

#Preview("Running Dark") {
    ContentView(
        viewModel: PreviewProxyViewModel(.running),
        initiallyExpandsWebsiteRouting: true
    )
    .frame(width: 840, height: 660)
    .preferredColorScheme(.dark)
}

#Preview("Stopped") {
    ContentView(viewModel: PreviewProxyViewModel(.stopped))
        .frame(width: 840, height: 660)
}

#Preview("Missing Tools") {
    ContentView(viewModel: PreviewProxyViewModel(.missingTools))
        .frame(width: 840, height: 660)
}

#Preview("Many Websites") {
    ContentView(
        viewModel: PreviewProxyViewModel(.manyWebsites),
        initiallyExpandsWebsiteRouting: true
    )
    .frame(width: 840, height: 660)
}

#Preview("Minimum Size") {
    ContentView(
        viewModel: PreviewProxyViewModel(.running),
        initiallyExpandsWebsiteRouting: true
    )
    .frame(width: 800, height: 600)
}
#endif
