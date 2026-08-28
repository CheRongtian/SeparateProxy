import Darwin
import Foundation
import XCTest
@testable import SeparateProxyCore

final class CodexExtensionDiscoveryTests: XCTestCase {
    func testDiscoversActiveOpenAICodexInstallation() throws {
        let fixture = try CodexExtensionFixture()
        defer { fixture.remove() }
        let active = try fixture.addInstallation(version: "1.2.3")
        try fixture.writeIndex([active.record])

        let installation = try fixture.discovery().discoverActiveInstallation()

        XCTAssertEqual(installation.version, "1.2.3")
        XCTAssertEqual(installation.extensionRootPath, active.root.path)
        XCTAssertEqual(installation.executablePath, active.codex.path)
    }

    func testObsoleteVersionsAreIgnoredInFavorOfActiveLocation() throws {
        let fixture = try CodexExtensionFixture()
        defer { fixture.remove() }
        let old = try fixture.addInstallation(version: "1.0.0")
        let active = try fixture.addInstallation(version: "2.0.0")
        try fixture.writeIndex([old.record, active.record])
        try fixture.writeObsolete([old.root.lastPathComponent: true])

        let installation = try fixture.discovery().discoverActiveInstallation()

        XCTAssertEqual(installation.version, "2.0.0")
        XCTAssertEqual(installation.extensionRootPath, active.root.path)
    }

    func testRejectsWrongPackagePublisherOrName() throws {
        let fixture = try CodexExtensionFixture()
        defer { fixture.remove() }
        let active = try fixture.addInstallation(
            version: "1.2.3",
            publisher: "someone-else"
        )
        try fixture.writeIndex([active.record])

        XCTAssertThrowsError(try fixture.discovery().discoverActiveInstallation()) { error in
            guard case .unsupportedInstallation = error as? CodexExtensionDiscoveryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsPackageVersionMismatch() throws {
        let fixture = try CodexExtensionFixture()
        defer { fixture.remove() }
        let active = try fixture.addInstallation(
            version: "1.2.3",
            packageVersion: "9.9.9"
        )
        try fixture.writeIndex([active.record])

        XCTAssertThrowsError(try fixture.discovery().discoverActiveInstallation()) { error in
            guard case .unsupportedInstallation = error as? CodexExtensionDiscoveryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsMissingCodexBinary() throws {
        let fixture = try CodexExtensionFixture()
        defer { fixture.remove() }
        let active = try fixture.addInstallation(version: "1.2.3")
        try FileManager.default.removeItem(at: active.codex)
        try fixture.writeIndex([active.record])

        XCTAssertThrowsError(try fixture.discovery().discoverActiveInstallation()) { error in
            guard case .incompleteInstallation = error as? CodexExtensionDiscoveryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsSymlinkedCodexBinary() throws {
        let fixture = try CodexExtensionFixture()
        defer { fixture.remove() }
        let active = try fixture.addInstallation(version: "1.2.3")
        let target = fixture.root.appendingPathComponent("synthetic-codex")
        try Data("test".utf8).write(to: target)
        try FileManager.default.removeItem(at: active.codex)
        try FileManager.default.createSymbolicLink(
            at: active.codex,
            withDestinationURL: target
        )
        try fixture.writeIndex([active.record])

        XCTAssertThrowsError(try fixture.discovery().discoverActiveInstallation()) { error in
            guard case .unsupportedInstallation = error as? CodexExtensionDiscoveryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCodexDisabledDoesNotExecuteDiscovery() throws {
        var discoveryWasCalled = false

        let installation = try CodexExtensionDiscovery.resolveIfEnabled(false) {
            discoveryWasCalled = true
            throw CodexExtensionDiscoveryError.notInstalled
        }

        XCTAssertNil(installation)
        XCTAssertFalse(discoveryWasCalled)
    }

    func testCodexValidationFailureStopsPreparation() {
        var downstreamPreparationRan = false

        XCTAssertThrowsError(try {
            _ = try CodexExtensionDiscovery.resolveIfEnabled(true) {
                throw CodexExtensionDiscoveryError.incompleteInstallation("synthetic failure")
            }
            downstreamPreparationRan = true
        }())
        XCTAssertFalse(downstreamPreparationRan)
    }
}

private final class CodexExtensionFixture {
    struct Installation {
        let root: URL
        let codex: URL
        let record: [String: Any]
    }

    let root: URL
    let home: URL
    let extensions: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-Codex-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        extensions = home
            .appendingPathComponent(".vscode", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extensions,
            withIntermediateDirectories: true
        )
    }

    func discovery() -> CodexExtensionDiscovery {
        CodexExtensionDiscovery(
            homeDirectory: home,
            expectedOwner: getuid()
        )
    }

    func addInstallation(
        version: String,
        publisher: String = "openai",
        name: String = "chatgpt",
        packageVersion: String? = nil
    ) throws -> Installation {
        let extensionRoot = extensions.appendingPathComponent(
            "openai.chatgpt-\(version)-darwin-arm64",
            isDirectory: true
        )
        let binaryDirectory = extensionRoot
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("macos-aarch64", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binaryDirectory,
            withIntermediateDirectories: true
        )

        let codex = binaryDirectory.appendingPathComponent("codex")
        try Data("synthetic executable".utf8).write(to: codex)
        guard chmod(codex.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let package: [String: Any] = [
            "publisher": publisher,
            "name": name,
            "version": packageVersion ?? version,
            "__metadata": ["targetPlatform": "darwin-arm64"],
        ]
        try writeJSONObject(
            package,
            to: extensionRoot.appendingPathComponent("package.json")
        )

        let record: [String: Any] = [
            "identifier": ["id": "openai.chatgpt"],
            "version": version,
            "location": [
                "scheme": "file",
                "path": extensionRoot.path,
                "fsPath": extensionRoot.path,
            ],
            "metadata": ["targetPlatform": "darwin-arm64"],
        ]
        return Installation(root: extensionRoot, codex: codex, record: record)
    }

    func writeIndex(_ records: [[String: Any]]) throws {
        try writeJSONObject(
            records,
            to: extensions.appendingPathComponent("extensions.json")
        )
    }

    func writeObsolete(_ values: [String: Bool]) throws {
        try writeJSONObject(
            values,
            to: extensions.appendingPathComponent(".obsolete")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeJSONObject(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url, options: .atomic)
    }
}
