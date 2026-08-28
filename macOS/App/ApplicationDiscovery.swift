import AppKit
import Darwin
import Foundation
import SeparateProxyCore

struct DiscoveredApplication: Identifiable, Equatable {
    let bundleIdentifier: String
    let name: String
    let bundleURL: URL
    let icon: NSImage

    var id: String { bundleIdentifier }
}

enum ApplicationDiscovery {
    static let chromeBundleIdentifier = "com.google.Chrome"

    @MainActor
    static func findGoogleChrome() -> DiscoveredApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: chromeBundleIdentifier
        ),
        url.isFileURL,
        url.pathExtension == "app",
        let bundle = Bundle(url: url),
        bundle.bundleIdentifier == chromeBundleIdentifier else {
            return nil
        }

        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Google Chrome"
        return DiscoveredApplication(
            bundleIdentifier: chromeBundleIdentifier,
            name: name,
            bundleURL: url.standardizedFileURL,
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )
    }
}

enum CodexTargetState: Equatable {
    case installed(CodexInstallation)
    case notInstalled
    case incompleteInstallation(String)
    case unsupportedInstallation(String)

    var installation: CodexInstallation? {
        guard case let .installed(installation) = self else { return nil }
        return installation
    }

    var canSelect: Bool {
        installation != nil
    }

    var label: String {
        switch self {
        case .installed:
            return "Installed"
        case .notInstalled:
            return "Not Installed"
        case .incompleteInstallation:
            return "Incomplete"
        case .unsupportedInstallation:
            return "Unsupported"
        }
    }

    var detail: String {
        switch self {
        case let .installed(installation):
            return "OpenAI VS Code extension \(installation.version)"
        case .notInstalled:
            return "The OpenAI Codex VS Code extension is not installed."
        case let .incompleteInstallation(reason), let .unsupportedInstallation(reason):
            return reason
        }
    }
}

enum CodexTargetDiscovery {
    static func discover() -> CodexTargetState {
        let discovery = CodexExtensionDiscovery(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            expectedOwner: getuid()
        )
        do {
            return .installed(try discovery.discoverActiveInstallation())
        } catch CodexExtensionDiscoveryError.notInstalled {
            return .notInstalled
        } catch let CodexExtensionDiscoveryError.incompleteInstallation(reason) {
            return .incompleteInstallation(reason)
        } catch let CodexExtensionDiscoveryError.unsupportedInstallation(reason) {
            return .unsupportedInstallation(reason)
        } catch {
            return .unsupportedInstallation(error.localizedDescription)
        }
    }
}
