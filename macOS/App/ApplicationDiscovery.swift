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
    static let visualStudioCodeBundleIdentifier = "com.microsoft.VSCode"

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

    @MainActor
    static func findVisualStudioCodeBundleURL() -> URL? {
        let runningCandidates = NSRunningApplication.runningApplications(
            withBundleIdentifier: visualStudioCodeBundleIdentifier
        )
        .compactMap(\.bundleURL)

        for candidate in runningCandidates {
            if let validated = validatedApplicationURL(
                candidate,
                bundleIdentifier: visualStudioCodeBundleIdentifier
            ) {
                return validated
            }
        }

        guard let candidate = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: visualStudioCodeBundleIdentifier
        ) else {
            return nil
        }
        return validatedApplicationURL(
            candidate,
            bundleIdentifier: visualStudioCodeBundleIdentifier
        )
    }

    private static func validatedApplicationURL(
        _ url: URL,
        bundleIdentifier: String
    ) -> URL? {
        guard url.isFileURL,
              url.pathExtension == "app",
              let bundle = Bundle(url: url),
              bundle.bundleIdentifier == bundleIdentifier else {
            return nil
        }
        return url.standardizedFileURL
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

enum GitTargetState: Equatable {
    case installed(AppleGitInstallation)
    case notFound
    case unsupported(String)

    var canSelect: Bool {
        guard case .installed = self else { return false }
        return true
    }

    var label: String {
        switch self {
        case .installed:
            return "Installed"
        case .notFound:
            return "Not Found"
        case .unsupported:
            return "Unsupported"
        }
    }

    var detail: String {
        switch self {
        case .installed:
            return "HTTPS remotes"
        case .notFound:
            return "Apple/Xcode Git was not found in the active developer directory."
        case let .unsupported(reason):
            return reason
        }
    }
}

enum GitTargetDiscovery {
    static func discover() -> GitTargetState {
        do {
            return .installed(try AppleGitDiscovery().discoverActiveInstallation())
        } catch AppleGitDiscoveryError.notInstalled {
            return .notFound
        } catch {
            return .unsupported(error.localizedDescription)
        }
    }
}

enum DockerHubTargetState: Equatable {
    case installed(DockerHubInstallation)
    case notFound
    case unsupported(String)

    var canSelect: Bool {
        guard case .installed = self else { return false }
        return true
    }

    var label: String {
        switch self {
        case .installed:
            return "Installed"
        case .notFound:
            return "Not Found"
        case .unsupported:
            return "Unsupported"
        }
    }

    var detail: String {
        switch self {
        case .installed:
            return "Registry HTTPS"
        case .notFound:
            return "Docker Desktop was not found."
        case let .unsupported(reason):
            return reason
        }
    }
}

enum DockerHubTargetDiscovery {
    @MainActor
    static func discover() -> DockerHubTargetState {
        let discovery = DockerHubDiscovery {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: DockerHubDiscovery.applicationBundleIdentifier
            )
        }
        do {
            return .installed(try discovery.discoverActiveInstallation())
        } catch DockerHubDiscoveryError.notInstalled {
            return .notFound
        } catch {
            return .unsupported(error.localizedDescription)
        }
    }
}
