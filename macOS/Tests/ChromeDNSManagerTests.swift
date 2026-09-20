import Darwin
import Foundation
import XCTest

final class ChromeDNSManagerTests: XCTestCase {
    private let historicalCloudflareTemplates = """
    {
       "servers": [ {
          "endpoints": [ {
             "ips": [ "1.1.1.1", "1.0.0.1" ]
          } ],
          "template": "https://one.one.one.one/dns-query{?dns}"
       } ]
    }
    """
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

    func testRemoveRestoresOriginalValuesWhenTargetStillMatches() throws {
        let originalDNS: [String: Any] = [
            "mode": "secure",
            "templates": "https://resolver.example/dns-query{?dns}",
            "automatic_mode_fallback_to_doh": true,
            "unrelated_dns_value": "preserve-me",
        ]
        try writeFixture(["dns_over_https": originalDNS, "other": 42])
        try installHistoricalIntegration()
        let manager = makeManager()

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
        try installHistoricalIntegration()
        let manager = makeManager()

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

    func testLegacyMigrationRejectsMalformedJSONWithoutChangingSourceFile() throws {
        try writeFixture(["dns_over_https": ["mode": "off"]])
        try installHistoricalIntegration()
        let malformed = Data(#"{"dns_over_https": "#.utf8)
        try malformed.write(to: localStateURL)
        let before = try Data(contentsOf: localStateURL)

        XCTAssertThrowsError(
            try makeManager().migrateLegacyIntegrationForWebsiteRouting()
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                ChromeDNSIntegrationError.malformedLocalState.localizedDescription
            )
        }
        XCTAssertEqual(try Data(contentsOf: localStateURL), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testLegacyMigrationUnexpectedDNSSchemaFailsClosed() throws {
        try writeFixture(["dns_over_https": ["mode": "off"]])
        try installHistoricalIntegration()
        try writeFixture(["dns_over_https": "unexpected"])
        let before = try Data(contentsOf: localStateURL)

        XCTAssertThrowsError(
            try makeManager().migrateLegacyIntegrationForWebsiteRouting()
        )
        XCTAssertEqual(try Data(contentsOf: localStateURL), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testAtomicReplacePreservesOriginalPermissions() throws {
        try writeFixture(["dns_over_https": ["mode": "off"]], permissions: 0o640)
        try installHistoricalIntegration()
        let before = try permissions(of: localStateURL)

        XCTAssertEqual(try makeManager().removeIntegration(), .removed)

        XCTAssertEqual(try permissions(of: localStateURL), before)
    }

    func testChromeRunningPreventsAnyLocalStateWrite() throws {
        try writeFixture(["dns_over_https": ["mode": "off"]])
        try installHistoricalIntegration()
        let before = try Data(contentsOf: localStateURL)
        chromeController.running = true
        let writer = RecordingChromeDNSLocalStateWriter()
        let manager = makeManager(writer: writer)

        XCTAssertThrowsError(try manager.removeIntegration()) { error in
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
        try installHistoricalIntegration()
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

        XCTAssertThrowsError(try manager.removeIntegration())
        XCTAssertEqual(writer.writeCount, 0)
        XCTAssertEqual(try Data(contentsOf: localStateURL), before)
    }

    func testRemoveDeletesPreferencesThatOriginallyDidNotExist() throws {
        try writeFixture([
            "dns_over_https": ["unrelated_dns_value": "preserve-me"],
            "other": 42,
        ])
        try installHistoricalIntegration()
        let manager = makeManager()

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

    func testLegacyMigrationRestoresAbsentPreferencesAndRemovesRecord() throws {
        try writeFixture([
            "dns_over_https": ["unrelated_dns_value": "preserve-me"],
            "other": 42,
        ])
        try installHistoricalIntegration()
        let manager = makeManager()

        XCTAssertEqual(
            try manager.migrateLegacyIntegrationForWebsiteRouting(),
            .restored
        )

        let root = try readFixture()
        let dns = try XCTUnwrap(root["dns_over_https"] as? [String: Any])
        XCTAssertNil(dns["mode"])
        XCTAssertNil(dns["templates"])
        XCTAssertNil(dns["automatic_mode_fallback_to_doh"])
        XCTAssertEqual(dns["unrelated_dns_value"] as? String, "preserve-me")
        XCTAssertEqual(root["other"] as? Int, 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testLegacyMigrationRestoresExactCustomPreferences() throws {
        let originalDNS: [String: Any] = [
            "mode": "secure",
            "templates": "https://resolver.example/dns-query{?dns}",
            "automatic_mode_fallback_to_doh": true,
        ]
        try writeFixture(["dns_over_https": originalDNS])
        try installHistoricalIntegration()
        let manager = makeManager()

        XCTAssertEqual(
            try manager.migrateLegacyIntegrationForWebsiteRouting(),
            .restored
        )

        let dns = try XCTUnwrap(
            try readFixture()["dns_over_https"] as? [String: Any]
        )
        XCTAssertEqual(dns["mode"] as? String, "secure")
        XCTAssertEqual(
            dns["templates"] as? String,
            "https://resolver.example/dns-query{?dns}"
        )
        XCTAssertEqual(dns["automatic_mode_fallback_to_doh"] as? Bool, true)
    }

    func testLegacyMigrationAllowsExternalChangeWithoutOverwritingIt() throws {
        try writeFixture(["dns_over_https": ["mode": "off"]])
        try installHistoricalIntegration()
        let manager = makeManager()

        var root = try readFixture()
        var dns = try XCTUnwrap(root["dns_over_https"] as? [String: Any])
        dns["mode"] = "secure"
        root["dns_over_https"] = dns
        try writeFixture(root)
        let beforeMigration = try Data(contentsOf: localStateURL)

        XCTAssertEqual(
            try manager.migrateLegacyIntegrationForWebsiteRouting(),
            .settingsChangedExternally
        )
        XCTAssertEqual(try Data(contentsOf: localStateURL), beforeMigration)
        XCTAssertEqual(manager.integrationState(), .modifiedExternally)
    }

    func testLegacyMigrationWriteFailureThrowsAndPreservesTargetPreferences() throws {
        try writeFixture(["dns_over_https": ["mode": "off"]])
        try installHistoricalIntegration()
        let beforeMigration = try Data(contentsOf: localStateURL)
        let failingManager = makeManager(writer: FailingChromeDNSLocalStateWriter())

        XCTAssertThrowsError(
            try failingManager.migrateLegacyIntegrationForWebsiteRouting()
        )
        XCTAssertEqual(try Data(contentsOf: localStateURL), beforeMigration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testLegacyMigrationUnexpectedSchemaFailsClosed() throws {
        try writeFixture(["dns_over_https": ["mode": "off"]])
        try installHistoricalIntegration()
        let manager = makeManager()
        try writeFixture(["dns_over_https": "unexpected"])
        let beforeMigration = try Data(contentsOf: localStateURL)

        XCTAssertThrowsError(
            try manager.migrateLegacyIntegrationForWebsiteRouting()
        )
        XCTAssertEqual(try Data(contentsOf: localStateURL), beforeMigration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testLegacyMigrationWithoutRecordIsNoOp() throws {
        let manager = makeManager()

        XCTAssertEqual(
            try manager.migrateLegacyIntegrationForWebsiteRouting(),
            .notNeeded
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: localStateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testLegacyMigrationDoesNotTouchECHBackup() throws {
        try writeFixture(["dns_over_https": ["mode": "off"]])
        try installHistoricalIntegration()
        let manager = makeManager()
        let echStateURL = integrationStateURL
            .deletingLastPathComponent()
            .appendingPathComponent("chrome-ech-integration.json")
        let echState = Data(#"{"version":1,"sentinel":"preserve-me"}"#.utf8)
        try echState.write(to: echStateURL)

        XCTAssertEqual(
            try manager.migrateLegacyIntegrationForWebsiteRouting(),
            .restored
        )
        XCTAssertEqual(try Data(contentsOf: echStateURL), echState)
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

    private func installHistoricalIntegration() throws {
        var root = try readFixture()
        let originalDNS = (root["dns_over_https"] as? [String: Any]) ?? [:]
        var installedDNS = originalDNS
        installedDNS["mode"] = "automatic"
        installedDNS["templates"] = historicalCloudflareTemplates
        installedDNS["automatic_mode_fallback_to_doh"] = false
        root["dns_over_https"] = installedDNS

        let installedData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try installedData.write(to: localStateURL)

        let original: [String: Any] = [
            "mode": storedPreference(key: "mode", in: originalDNS),
            "templates": storedPreference(key: "templates", in: originalDNS),
            "automaticModeFallbackToDoh": storedPreference(
                key: "automatic_mode_fallback_to_doh",
                in: originalDNS
            ),
        ]
        let record: [String: Any] = [
            "version": 1,
            "phase": "installed",
            "original": original,
        ]
        try FileManager.default.createDirectory(
            at: integrationStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let recordData = try JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        )
        try recordData.write(to: integrationStateURL)
    }

    private func storedPreference(
        key: String,
        in dictionary: [String: Any]
    ) -> [String: Any] {
        guard let value = dictionary[key] else {
            return ["existed": false]
        }
        return ["existed": true, "value": value]
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

    private func permissions(of url: URL) throws -> mode_t {
        var info = stat()
        XCTAssertEqual(Darwin.lstat(url.path, &info), 0)
        return info.st_mode & 0o7777
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
