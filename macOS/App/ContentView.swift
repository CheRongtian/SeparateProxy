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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SeparateProxy")
                .font(.largeTitle.bold())
            Text("Route Google Chrome through Outline while other applications remain direct.")
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
                                HStack(spacing: 4) {
                                    Text("Secure DNS:")
                                    Text(viewModel.chromeDNSStateLabel)
                                        .foregroundStyle(chromeDNSStatusColor)
                                }
                                .font(.caption)
                                .help(viewModel.chromeDNSMessage)
                            }
                        }
                    }
                    chromeDNSMenu
                }
            } else {
                Label("Google Chrome was not found.", systemImage: "app.dashed")
                    .foregroundStyle(.secondary)
            }
        }
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

    private var chromeDNSMenu: some View {
        Menu {
            switch viewModel.chromeDNSState {
            case .notConfigured, .chromeRunning, .readyToConfigure:
                Button(viewModel.chromeDNSConfigureButtonTitle) {
                    viewModel.configureChromeDNS()
                }
            case .configuring:
                Button("Updating Secure DNS...") {}
                    .disabled(true)
            case .configured:
                if viewModel.chromeDNSCanRemove {
                    Button(viewModel.chromeDNSRemoveButtonTitle, role: .destructive) {
                        viewModel.removeChromeDNSIntegration()
                    }
                }
            case .modifiedExternally, .unsupported, .error:
                EmptyView()
            }

            Divider()
            Button("Refresh Secure DNS Status") {
                viewModel.refresh()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Secure DNS Actions")
    }

    private var chromeDNSStatusColor: Color {
        switch viewModel.chromeDNSState {
        case .configured:
            return .green
        case .modifiedExternally, .unsupported, .error:
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
