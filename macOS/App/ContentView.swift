import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ProxyViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            keySection
            applicationSection
            developerToolsSection
            Divider()
            statusSection
            trafficSection
            controls
        }
        .padding(24)
        .frame(width: 560)
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
                .font(.largeTitle.bold())
            Text("Route selected Chrome websites and developer tools through Outline.")
                .foregroundStyle(.secondary)
        }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Outline Access Key")
                    .font(.headline)
                Spacer()
                Label(
                    viewModel.keyIsSaved ? "Saved in Keychain" : "Not Saved",
                    systemImage: viewModel.keyIsSaved ? "checkmark.shield" : "exclamationmark.triangle"
                )
                .foregroundStyle(viewModel.keyIsSaved ? .green : .secondary)
            }

            SecureField(
                viewModel.keyIsSaved ? "Enter a replacement ss:// key" : "Enter an ss:// key",
                text: $viewModel.accessKeyInput
            )
            .textFieldStyle(.roundedBorder)

            HStack {
                Button(viewModel.keyIsSaved ? "Replace Key" : "Save Key") {
                    viewModel.saveAccessKey()
                }
                .disabled(viewModel.accessKeyInput.isEmpty)

                if viewModel.keyIsSaved {
                    Button("Remove Key", role: .destructive) {
                        viewModel.deleteAccessKey()
                    }
                }
            }
        }
    }

    private var applicationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Applications")
                .font(.headline)

            if let chrome = viewModel.chrome {
                HStack(alignment: .top, spacing: 8) {
                    Toggle(isOn: $viewModel.chromeIsSelected) {
                        HStack(spacing: 10) {
                            Image(nsImage: chrome.icon)
                                .resizable()
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chrome.name)
                                Text(chrome.bundleURL.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let legacyDNSStatus = viewModel.chromeLegacyDNSStatusLabel {
                                    Text(legacyDNSStatus)
                                        .font(.caption)
                                        .foregroundStyle(chromeDNSStatusColor)
                                        .help(viewModel.chromeDNSMessage)
                                }
                                HStack(spacing: 4) {
                                    Text("Website Routing ECH:")
                                    Text(viewModel.chromeECHStateLabel)
                                        .foregroundStyle(chromeECHStatusColor)
                                }
                                .font(.caption)
                                .help(viewModel.chromeECHMessage)
                            }
                        }
                    }
                    chromeIntegrationMenu
                }
                proxyWebsitesSection
            } else {
                Label("Google Chrome was not found.", systemImage: "app.dashed")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var proxyWebsitesSection: some View {
        DisclosureGroup("Proxy Websites (\(viewModel.proxyWebsiteHostnames.count))") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(
                        "https://example.com/path",
                        text: $viewModel.proxyWebsiteInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.addProxyWebsite()
                    }
                    Button("Add") {
                        viewModel.addProxyWebsite()
                    }
                    .disabled(viewModel.proxyWebsiteInput.isEmpty)
                }

                if viewModel.proxyWebsiteHostnames.isEmpty {
                    Text("Chrome remains direct while no Proxy Websites are configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.proxyWebsiteHostnames, id: \.self) { hostname in
                                HStack {
                                    Text("https://\(hostname)")
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button(role: .destructive) {
                                        viewModel.removeProxyWebsite(hostname)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove \(hostname)")
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }

                Text("Exact hostnames only. Changes made while running apply on the next Start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    private var statusSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Status")
                    .font(.headline)
                Text(viewModel.stateLabel)
                    .font(.title3.bold())
                Text(viewModel.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh Status")
        }
    }

    private var developerToolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Developer Tools")
                .font(.headline)

            Toggle(isOn: $viewModel.codexIsSelected) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "terminal")
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Codex")
                            Spacer()
                            Text(viewModel.codexTargetState.label)
                                .font(.caption.bold())
                                .foregroundStyle(codexStatusColor)
                        }
                        Text(viewModel.codexTargetDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!viewModel.codexTargetState.canSelect)

            Toggle(isOn: $viewModel.gitIsSelected) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Git")
                            Spacer()
                            Text(viewModel.gitTargetState.label)
                                .font(.caption.bold())
                                .foregroundStyle(gitStatusColor)
                        }
                        Text(viewModel.gitTargetState.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!viewModel.gitTargetState.canSelect)
        }
    }

    private var trafficSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Traffic")
                    .font(.headline)
                Spacer()
                if viewModel.trafficIsUnavailable {
                    Text("Traffic unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            trafficRow(
                title: "Proxy",
                upload: viewModel.proxyUploadSpeedLabel,
                download: viewModel.proxyDownloadSpeedLabel
            )
            trafficRow(
                title: "Direct",
                upload: viewModel.directUploadSpeedLabel,
                download: viewModel.directDownloadSpeedLabel
            )
        }
    }

    private func trafficRow(
        title: String,
        upload: String,
        download: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 52, alignment: .leading)
            Spacer()
            Label(upload, systemImage: "arrow.up")
                .frame(width: 112, alignment: .trailing)
            Label(download, systemImage: "arrow.down")
                .frame(width: 112, alignment: .trailing)
        }
        .font(.callout.monospacedDigit())
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
            return .secondary
        }
    }

    private var gitStatusColor: Color {
        switch viewModel.gitTargetState {
        case .installed:
            return .green
        case .notFound, .unsupported:
            return .secondary
        }
    }

    private var controls: some View {
        HStack {
            switch viewModel.state {
            case .helperNotInstalled:
                Button("Enable Helper") {
                    viewModel.enableHelper()
                }
                .buttonStyle(.borderedProminent)
            case .approvalRequired:
                Button("Open System Settings") {
                    viewModel.openHelperSettings()
                }
                .buttonStyle(.borderedProminent)
            case .running:
                Button("Stop Proxy") {
                    viewModel.stop()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStop)
            case .starting, .stopping:
                ProgressView()
                Text(viewModel.stateLabel)
            case .stopped, .error:
                Button("Start Proxy") {
                    viewModel.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStart)
            }
            Spacer()
        }
    }
}
