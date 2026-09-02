import AppKit
import Foundation
import SeparateProxyCore

final class HelperService: NSObject, SeparateProxyHelperProtocol {
    private let queue = DispatchQueue(label: "com.cherongtian.SeparateProxy.Helper.operations")
    private let runtimeStore: SecureRuntimeStore
    private let controller: SingBoxController
    private let trafficAccountingReader: TrafficAccountingReader

    override init() {
        let runtimeStore = SecureRuntimeStore()
        self.runtimeStore = runtimeStore
        trafficAccountingReader = TrafficAccountingReader()
        do {
            controller = try SingBoxController(runtimeStore: runtimeStore)
        } catch {
            fatalError("Unable to initialize the bundled sing-box controller: \(error.localizedDescription)")
        }
        super.init()
    }

    func status(withReply reply: @escaping (NSDictionary) -> Void) {
        queue.async {
            do {
                let state = try self.controller.state()
                reply(self.reply(success: true, state: state, message: self.message(for: state)))
            } catch {
                reply(self.reply(success: false, state: .error, message: error.localizedDescription))
            }
        }
    }

    func startProxy(
        accessKey: String,
        chromeBundlePath: String,
        codexEnabled: Bool,
        gitEnabled: Bool,
        dockerEnabled: Bool,
        vsCodeBundlePath: String,
        proxyWebsiteHostnames: [String],
        withReply reply: @escaping (NSDictionary) -> Void
    ) {
        queue.async {
            do {
                let validatedChromePath = chromeBundlePath.isEmpty
                    ? nil
                    : try self.validateChromeBundle(at: chromeBundlePath)
                let codexInstallation = try CodexExtensionDiscovery.resolveIfEnabled(
                    codexEnabled
                ) {
                    try CodexExtensionDiscovery
                        .forConsoleUser()
                        .discoverActiveInstallation()
                }
                let vsCodePluginHelper = try VSCodePluginHelperValidator.resolveIfEnabled(
                    codexEnabled
                ) {
                    try VSCodePluginHelperValidator().validateBundle(
                        atPath: vsCodeBundlePath
                    )
                }
                let gitInstallation = try AppleGitDiscovery.resolveIfEnabled(
                    gitEnabled
                ) {
                    try AppleGitDiscovery().discoverActiveInstallation()
                }
                let dockerHubInstallation = try DockerHubDiscovery.resolveIfEnabled(
                    dockerEnabled
                ) {
                    try DockerHubDiscovery {
                        NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: DockerHubDiscovery.applicationBundleIdentifier
                        )
                    }.discoverActiveInstallation()
                }
                let outline = try OutlineAccessKeyParser.parse(accessKey)
                let validatedProxyWebsiteHostnames = try ProxyWebsiteHostnameNormalizer
                    .validateNormalizedList(proxyWebsiteHostnames)
                let configuration: SingBoxConfiguration
                if codexEnabled || gitEnabled || dockerEnabled {
                    configuration = try SingBoxConfigurationBuilder.make(
                        outline: outline,
                        chromeBundlePath: validatedChromePath,
                        codexExecutablePath: codexInstallation?.executablePath,
                        vsCodePluginHelperExecutablePath: vsCodePluginHelper?.executablePath,
                        gitInstallation: gitInstallation,
                        dockerHubInstallation: dockerHubInstallation,
                        proxyWebsiteHostnames: validatedProxyWebsiteHostnames
                    )
                } else {
                    guard let validatedChromePath else {
                        throw SingBoxConfigurationError.invalidChromeBundlePath
                    }
                    configuration = try SingBoxConfigurationBuilder.make(
                        outline: outline,
                        chromeBundlePath: validatedChromePath,
                        proxyWebsiteHostnames: validatedProxyWebsiteHostnames
                    )
                }
                try self.runtimeStore.writeConfig(configuration.encodedJSON())
                do {
                    try self.controller.checkConfiguration(
                        redacting: [accessKey, outline.password]
                    )
                    let pid = try self.controller.start()
                    reply(self.reply(
                        success: true,
                        state: .running,
                        message: "The proxy is running. PID: \(pid)."
                    ))
                } catch {
                    try? self.runtimeStore.removeConfig()
                    throw error
                }
            } catch {
                reply(self.reply(success: false, state: .error, message: error.localizedDescription))
            }
        }
    }

    func stopProxy(withReply reply: @escaping (NSDictionary) -> Void) {
        queue.async {
            do {
                try self.controller.stop()
                reply(self.reply(success: true, state: .stopped, message: "The proxy is stopped."))
            } catch {
                reply(self.reply(success: false, state: .error, message: error.localizedDescription))
            }
        }
    }

    func getTrafficCounters(withReply reply: @escaping (NSDictionary) -> Void) {
        queue.async {
            do {
                let snapshot = try self.trafficAccountingReader.readSnapshot()
                reply(TrafficAccountingReplyBuilder.success(snapshot))
            } catch {
                reply(TrafficAccountingReplyBuilder.failure(error))
            }
        }
    }

    private func validateChromeBundle(at path: String) throws -> String {
        guard path.hasPrefix("/"), path.hasSuffix(".app") else {
            throw SingBoxConfigurationError.invalidChromeBundlePath
        }
        let url = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard url.pathExtension == "app",
              let bundle = Bundle(url: url),
              bundle.bundleIdentifier == ApplicationIdentity.chromeBundleIdentifier else {
            throw SingBoxConfigurationError.invalidChromeBundlePath
        }
        return url.path
    }

    private func reply(success: Bool, state: ProxyState, message: String) -> NSDictionary {
        [
            HelperReplyKey.success: success,
            HelperReplyKey.state: state.rawValue,
            HelperReplyKey.message: message,
        ]
    }

    private func message(for state: ProxyState) -> String {
        switch state {
        case .running:
            return "The proxy is running."
        case .stopped:
            return "The proxy is stopped."
        default:
            return "The helper reported \(state.rawValue)."
        }
    }
}

private enum ApplicationIdentity {
    static let chromeBundleIdentifier = "com.google.Chrome"
}
