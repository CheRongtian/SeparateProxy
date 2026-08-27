import Darwin
import Foundation
import XCTest

final class ChromeDNSManagerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var localStateURL: URL!
    private var integrationStateURL: URL!
    private var chromeController: FakeChromeApplicationController!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-ChromeDNS-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        localStateURL = temporaryDirectory.appendingPathComponent("Local State")
        integrationStateURL = temporaryDirectory
            .appendingPathComponent("state")
            .appendingPathComponent("chrome-dns-integration.json")
        chromeController = FakeChromeApplicationController()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testConfigureAddsTargetPreferencesWhenTheyWereAbsent() throws {
        try writeFixture(["unrelated": ["preserved": true]])
        let manager = makeManager()

        try manager.configure()

        let root = try readFixture()
        let dns = try XCTUnwrap(root["dns_over_https"] as? [String: Any])
        XCTAssertEqual(dns["mode"] as? String, "automatic")
        XCTAssertEqual(dns["templates"] as? String, ChromeDNSManager.cloudflareTemplates)
        XCTAssertEqual(dns["automatic_mode_fallback_to_doh"] as? Bool, false)
        let unrelated = try XCTUnwrap(root["unrelated"] as? [String: Any])
        XCTAssertEqual(unrelated["preserved"] as? Bool, true)
    }

    func testConfigureStoresExistenceAndOriginalValuesOnly() throws {
        try writeFixture([
            "dns_over_https": [
                "mode": "secure",
                "templates": "https://resolver.example/dns-query{?dns}",
                "automatic_mode_fallback_to_doh": true,
                "unrelated_dns_value": "preserve-me",
            ],
            "other": 42,
        ])

        try makeManager().configure()

        let record = try readIntegrationRecord()
        XCTAssertEqual(record["version"] as? Int, 1)
        XCTAssertEqual(record["phase"] as? String, "installed")
        let original = try XCTUnwrap(record["original"] as? [String: Any])
        assertStoredPreference(original["mode"], existed: true, value: "secure")
        assertStoredPreference(
            original["templates"],
            existed: true,
            value: "https://resolver.example/dns-query{?dns}"
        )
        assertStoredPreference(
            original["automaticModeFallbackToDoh"],
            existed: true,
            value: true
        )
        XCTAssertEqual(Set(original.keys), [
            "mode",
            "templates",
            "automaticModeFallbackToDoh",
        ])
    }

    func testRemoveRestoresOriginalValuesWhenTargetStillMatches() throws {
        let originalDNS: [String: Any] = [
            "mode": "secure",
            "templates": "https://resolver.example/dns-query{?dns}",
            "automatic_mode_fallback_to_doh": true,
            "unrelated_dns_value": "preserve-me",
        ]
        try writeFixture(["dns_over_https": originalDNS, "other": 42])
        let manager = makeManager()
        try manager.configure()

        XCTAssertEqual(try manager.removeIntegration(), .removed)

        let root = try readFixture()
        let dns = try XCTUnwrap(root["dns_over_https"] as? [String: Any])
        XCTAssertEqual(dns["mode"] as? String, "secure")
        XCTAssertEqual(
            dns["templates"] as? String,
            "https://resolver.example/dns-query{?dns}"
        )
        XCTAssertEqual(dns["automatic_mode_fallback_to_doh"] as? Bool, true)
        XCTAssertEqual(dns["unrelated_dns_value"] as? String, "preserve-me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testRemoveDoesNotOverwriteSettingsChangedExternally() throws {
        try writeFixture(["dns_over_https": ["mode": "off"]])
        let manager = makeManager()
        try manager.configure()

        var externallyModified = try readFixture()
        var dns = try XCTUnwrap(externallyModified["dns_over_https"] as? [String: Any])
        dns["mode"] = "secure"
        externallyModified["dns_over_https"] = dns
        try writeFixture(externallyModified)
        let beforeRemoval = try Data(contentsOf: localStateURL)

        XCTAssertEqual(
            try manager.removeIntegration(),
            .settingsChangedExternally
        )
        XCTAssertEqual(try Data(contentsOf: localStateURL), beforeRemoval)
        XCTAssertEqual(manager.integrationState(), .modifiedExternally)
    }

    func testMalformedJSONIsRejectedWithoutChangingSourceFile() throws {
        let malformed = Data(#"{"dns_over_https": "#.utf8)
        try malformed.write(to: localStateURL)
        let before = try Data(contentsOf: localStateURL)

        XCTAssertThrowsError(try makeManager().configure()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                ChromeDNSIntegrationError.malformedLocalState.localizedDescription
            )
        }
        XCTAssertEqual(try Data(contentsOf: localStateURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testUnexpectedDNSSchemaFailsClosed() throws {
        try writeFixture(["dns_over_https": "unexpected"])
        let before = try Data(contentsOf: localStateURL)

        XCTAssertThrowsError(try makeManager().configure())
        XCTAssertEqual(try Data(contentsOf: localStateURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testTemporaryWriteFailureLeavesOriginalFileIntact() throws {
        try writeFixture(["dns_over_https": ["mode": "off"], "preserved": true])
        let before = try Data(contentsOf: localStateURL)
        let manager = makeManager(writer: FailingChromeDNSLocalStateWriter())

        XCTAssertThrowsError(try manager.configure())
        XCTAssertEqual(try Data(contentsOf: localStateURL), before)
    }

    func testAtomicReplacePreservesOriginalPermissions() throws {
        try writeFixture(["dns_over_https": ["mode": "off"]], permissions: 0o640)
        let before = try permissions(of: localStateURL)

        try makeManager().configure()

        XCTAssertEqual(try permissions(of: localStateURL), before)
    }

    func testChromeRunningPreventsAnyLocalStateWrite() throws {
        try writeFixture(["dns_over_https": ["mode": "off"]])
        let before = try Data(contentsOf: localStateURL)
        chromeController.running = true
        let writer = RecordingChromeDNSLocalStateWriter()
        let manager = makeManager(writer: writer)

        XCTAssertThrowsError(try manager.configure()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                ChromeDNSIntegrationError.chromeRunning.localizedDescription
            )
        }
        XCTAssertEqual(writer.writeCount, 0)
        XCTAssertEqual(try Data(contentsOf: localStateURL), before)
    }

    func testChromeRestartBeforeAtomicWriteAbortsWithoutChangingLocalState() throws {
        try writeFixture(["dns_over_https": ["mode": "off"]])
        let before = try Data(contentsOf: localStateURL)
        let controller = SequencedChromeApplicationController(
            runningResults: [false, true]
        )
        let writer = RecordingChromeDNSLocalStateWriter()
        let manager = ChromeDNSManager(
            localStateURL: localStateURL,
            integrationStateURL: integrationStateURL,
            applicationController: controller,
            localStateWriter: writer
        )

        XCTAssertThrowsError(try manager.configure())
        XCTAssertEqual(writer.writeCount, 0)
        XCTAssertEqual(try Data(contentsOf: localStateURL), before)
    }

    func testRemoveDeletesPreferencesThatOriginallyDidNotExist() throws {
        try writeFixture([
            "dns_over_https": ["unrelated_dns_value": "preserve-me"],
            "other": 42,
        ])
        let manager = makeManager()
        try manager.configure()

        XCTAssertEqual(try manager.removeIntegration(), .removed)

        let root = try readFixture()
        let dns = try XCTUnwrap(root["dns_over_https"] as? [String: Any])
        XCTAssertNil(dns["mode"])
        XCTAssertNil(dns["templates"])
        XCTAssertNil(dns["automatic_mode_fallback_to_doh"])
        XCTAssertEqual(dns["unrelated_dns_value"] as? String, "preserve-me")
        XCTAssertEqual(root["other"] as? Int, 42)
    }

    func testCloudflareTemplatePreservesVerifiedBootstrapEndpoints() throws {
        let data = Data(ChromeDNSManager.cloudflareTemplates.utf8)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let servers = try XCTUnwrap(object["servers"] as? [[String: Any]])
        let server = try XCTUnwrap(servers.first)
        XCTAssertEqual(
            server["template"] as? String,
            "https://one.one.one.one/dns-query{?dns}"
        )
        let endpoints = try XCTUnwrap(server["endpoints"] as? [[String: Any]])
        XCTAssertEqual(
            endpoints.first?["ips"] as? [String],
            ["1.1.1.1", "1.0.0.1"]
        )
    }

    private func makeManager(
        writer: ChromeDNSLocalStateWriting = POSIXChromeDNSLocalStateWriter()
    ) -> ChromeDNSManager {
        ChromeDNSManager(
            localStateURL: localStateURL,
            integrationStateURL: integrationStateURL,
            applicationController: chromeController,
            localStateWriter: writer
        )
    }

    private func writeFixture(
        _ root: [String: Any],
        permissions: mode_t = 0o600
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: localStateURL)
        XCTAssertEqual(Darwin.chmod(localStateURL.path, permissions), 0)
    }

    private func readFixture() throws -> [String: Any] {
        let data = try Data(contentsOf: localStateURL)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func readIntegrationRecord() throws -> [String: Any] {
        let data = try Data(contentsOf: integrationStateURL)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func permissions(of url: URL) throws -> mode_t {
        var info = stat()
        XCTAssertEqual(Darwin.lstat(url.path, &info), 0)
        return info.st_mode & 0o7777
    }

    private func assertStoredPreference(
        _ object: Any?,
        existed: Bool,
        value: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let dictionary = object as? [String: Any] else {
            XCTFail("Stored preference is missing", file: file, line: line)
            return
        }
        XCTAssertEqual(dictionary["existed"] as? Bool, existed, file: file, line: line)
        switch value {
        case let expected as String:
            XCTAssertEqual(
                dictionary["value"] as? String,
                expected,
                file: file,
                line: line
            )
        case let expected as Bool:
            XCTAssertEqual(
                dictionary["value"] as? Bool,
                expected,
                file: file,
                line: line
            )
        default:
            XCTFail("Unsupported stored preference type", file: file, line: line)
        }
    }
}

private final class FakeChromeApplicationController: ChromeApplicationControlling {
    var running = false
    private(set) var terminationRequested = false
    private(set) var reopenRequested = false

    func isChromeRunning() -> Bool {
        running
    }

    func requestChromeTermination() -> Bool {
        terminationRequested = true
        return true
    }

    func reopenChrome() throws {
        reopenRequested = true
    }
}

private final class SequencedChromeApplicationController: ChromeApplicationControlling {
    private var runningResults: [Bool]

    init(runningResults: [Bool]) {
        self.runningResults = runningResults
    }

    func isChromeRunning() -> Bool {
        guard !runningResults.isEmpty else {
            return false
        }
        return runningResults.removeFirst()
    }

    func requestChromeTermination() -> Bool {
        true
    }

    func reopenChrome() throws {}
}

private final class FailingChromeDNSLocalStateWriter: ChromeDNSLocalStateWriting {
    func replaceFile(
        at url: URL,
        with data: Data,
        preserving metadata: ChromeDNSFileMetadata
    ) throws {
        throw ChromeDNSIntegrationError.fileOperation("synthetic write failure")
    }
}

private final class RecordingChromeDNSLocalStateWriter: ChromeDNSLocalStateWriting {
    private(set) var writeCount = 0

    func replaceFile(
        at url: URL,
        with data: Data,
        preserving metadata: ChromeDNSFileMetadata
    ) throws {
        writeCount += 1
    }
}
