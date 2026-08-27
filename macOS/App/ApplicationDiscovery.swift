import AppKit
import Foundation

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
