import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ProxyViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            keySection
            applicationSection
            Divider()
            chromeDNSSection
            Divider()
            statusSection
            controls
        }
        .padding(24)
        .frame(width: 560)
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
                        }
                    }
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

    private var chromeDNSSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chrome DNS Integration")
                    .font(.headline)
                Spacer()
                Text(viewModel.chromeDNSStateLabel)
                    .font(.subheadline.bold())
                    .foregroundStyle(chromeDNSStatusColor)
            }

            Text(viewModel.chromeDNSMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Chrome prefers Cloudflare DoH. If DoH is unavailable in automatic mode, Chrome may fall back to the macOS system resolver.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                switch viewModel.chromeDNSState {
                case .notConfigured, .chromeRunning, .readyToConfigure:
                    Button(viewModel.chromeDNSConfigureButtonTitle) {
                        viewModel.configureChromeDNS()
                    }
                    .buttonStyle(.borderedProminent)
                case .configuring:
                    ProgressView()
                    Text("Updating Chrome DNS integration...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .configured:
                    if viewModel.chromeDNSCanRemove {
                        Button(viewModel.chromeDNSRemoveButtonTitle, role: .destructive) {
                            viewModel.removeChromeDNSIntegration()
                        }
                    }
                case .modifiedExternally, .unsupported, .error:
                    EmptyView()
                }
                Spacer()
            }
        }
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
