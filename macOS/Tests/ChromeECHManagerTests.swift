import Darwin
import Foundation
import XCTest

final class ChromeECHManagerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var localStateURL: URL!
    private var integrationStateURL: URL!
    private var chromeController: ECHFakeChromeApplicationController!
    private var policyProvider: FakeChromeECHPolicyProvider!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-ChromeECH-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        localStateURL = temporaryDirectory.appendingPathComponent("Local State")
        integrationStateURL = temporaryDirectory
            .appendingPathComponent("state/chrome-ech-integration.json")
        chromeController = ECHFakeChromeApplicationController()
        policyProvider = FakeChromeECHPolicyProvider(state: .notManaged)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testConfigureCreatesSSLObjectAndRestoreRemovesItWhenOriginallyAbsent() throws {
        try writeFixture(["unrelated": true])
        let manager = makeManager()

        try manager.configure()
        var root = try readFixture()
        let ssl = try XCTUnwrap(root["ssl"] as? [String: Any])
        XCTAssertEqual(ssl["ech_enabled"] as? Bool, false)
        XCTAssertEqual(root["unrelated"] as? Bool, true)
        XCTAssertEqual(manager.requirementState(), .configured)

        let record = try readIntegrationRecord()
        let original = try XCTUnwrap(record["original"] as? [String: Any])
        XCTAssertEqual(original["sslObjectExisted"] as? Bool, false)
        let ech = try XCTUnwrap(original["echEnabled"] as? [String: Any])
        XCTAssertEqual(ech["existed"] as? Bool, false)
        XCTAssertNil(ech["value"])

        XCTAssertEqual(try manager.removeIntegration(), .removed)
        root = try readFixture()
        XCTAssertNil(root["ssl"])
        XCTAssertEqual(root["unrelated"] as? Bool, true)
    }

    func testConfigureAndRestoreExistingPreferencePreservesOtherSSLFields() throws {
        try writeFixture([
            "ssl": ["ech_enabled": true, "unrelated_ssl": "keep"],
            "dns_over_https": ["mode": "automatic"],
        ])
        let manager = makeManager()

        try manager.configure()
        XCTAssertEqual(try manager.removeIntegration(), .removed)

        let root = try readFixture()
        let ssl = try XCTUnwrap(root["ssl"] as? [String: Any])
        XCTAssertEqual(ssl["ech_enabled"] as? Bool, true)
        XCTAssertEqual(ssl["unrelated_ssl"] as? String, "keep")
        XCTAssertEqual(
            (root["dns_over_https"] as? [String: Any])?["mode"] as? String,
            "automatic"
        )
    }

    func testExistingFalsePreferenceIsRecordedAndRestoredAsFalse() throws {
        try writeFixture(["ssl": ["ech_enabled": false, "preserved": true]])
        let manager = makeManager()

        try manager.configure()
        XCTAssertTrue(manager.hasRestorableIntegration())
        let record = try readIntegrationRecord()
        let original = try XCTUnwrap(record["original"] as? [String: Any])
        let ech = try XCTUnwrap(original["echEnabled"] as? [String: Any])
        XCTAssertEqual(ech["existed"] as? Bool, true)
        XCTAssertEqual(ech["value"] as? Bool, false)

        XCTAssertEqual(try manager.removeIntegration(), .removed)
        let ssl = try XCTUnwrap(try readFixture()["ssl"] as? [String: Any])
        XCTAssertEqual(ssl["ech_enabled"] as? Bool, false)
        XCTAssertEqual(ssl["preserved"] as? Bool, true)
    }

    func testRemoveDoesNotOverwriteExternalChange() throws {
        try writeFixture(["ssl": ["ech_enabled": true]])
        let manager = makeManager()
        try manager.configure()

        var root = try readFixture()
        var ssl = try XCTUnwrap(root["ssl"] as? [String: Any])
        ssl["ech_enabled"] = true
        root["ssl"] = ssl
        try writeFixture(root)
        let before = try Data(contentsOf: localStateURL)

        XCTAssertEqual(
            try manager.removeIntegration(),
            .settingsChangedExternally
        )
        XCTAssertEqual(try Data(contentsOf: localStateURL), before)
        XCTAssertEqual(manager.requirementState(), .modifiedExternally)
    }

    func testManagedDisabledPolicySatisfiesRequirementWithoutWriting() throws {
        try writeFixture(["ssl": ["ech_enabled": true]])
        policyProvider.state = .disabled
        let writer = ECHRecordingLocalStateWriter()
        let manager = makeManager(writer: writer)

        XCTAssertTrue(try manager.isRequirementSatisfied())
        try manager.configure()
        XCTAssertEqual(manager.requirementState(), .satisfiedByManagedPolicy)
        XCTAssertEqual(writer.writeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testManagedEnabledPolicyBlocksRequirementAndConfiguration() throws {
        try writeFixture(["ssl": ["ech_enabled": false]])
        policyProvider.state = .enabled
        let manager = makeManager()

        XCTAssertThrowsError(try manager.isRequirementSatisfied())
        XCTAssertThrowsError(try manager.configure())
        XCTAssertEqual(manager.requirementState(), .managedEnabled)
    }

    func testMalformedOrUnexpectedSchemaLeavesSourceUnchanged() throws {
        try Data(#"{"ssl": "unexpected"}"#.utf8).write(to: localStateURL)
        let before = try Data(contentsOf: localStateURL)

        XCTAssertThrowsError(try makeManager().configure())
        XCTAssertEqual(try Data(contentsOf: localStateURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testChromeRunningPreventsWrite() throws {
        try writeFixture(["ssl": ["ech_enabled": true]])
        chromeController.running = true
        let writer = ECHRecordingLocalStateWriter()

        XCTAssertThrowsError(try makeManager(writer: writer).configure())
        XCTAssertEqual(writer.writeCount, 0)
    }

    func testChromeRestartBeforeAtomicWriteAbortsWithoutChangingLocalState() throws {
        try writeFixture(["ssl": ["ech_enabled": true]])
        let before = try Data(contentsOf: localStateURL)
        let controller = ECHSequencedChromeApplicationController(
            runningResults: [false, true]
        )
        let writer = ECHRecordingLocalStateWriter()
        let manager = ChromeECHManager(
            localStateURL: localStateURL,
            integrationStateURL: integrationStateURL,
            applicationController: controller,
            localStateWriter: writer,
            policyProvider: policyProvider
        )

        XCTAssertThrowsError(try manager.configure())
        XCTAssertEqual(writer.writeCount, 0)
        XCTAssertEqual(try Data(contentsOf: localStateURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testExistingDNSIntegrationBackupRemainsByteForByteUnchanged() throws {
        try writeFixture([
            "dns_over_https": ["mode": "automatic"],
            "ssl": ["ech_enabled": true],
        ])
        let dnsBackupURL = temporaryDirectory
            .appendingPathComponent("state/chrome-dns-integration.json")
        try FileManager.default.createDirectory(
            at: dnsBackupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dnsBackup = Data(#"{"version":1,"dns":"preserve-exactly"}"#.utf8)
        try dnsBackup.write(to: dnsBackupURL)

        try makeManager().configure()

        XCTAssertEqual(try Data(contentsOf: dnsBackupURL), dnsBackup)
        XCTAssertEqual(
            (try readFixture()["dns_over_https"] as? [String: Any])?["mode"] as? String,
            "automatic"
        )
    }

    func testWriteFailureLeavesOriginalFileIntactAndRemovesPreparingRecord() throws {
        try writeFixture(["ssl": ["ech_enabled": true], "preserved": 42])
        let before = try Data(contentsOf: localStateURL)

        XCTAssertThrowsError(
            try makeManager(writer: ECHFailingLocalStateWriter()).configure()
        )
        XCTAssertEqual(try Data(contentsOf: localStateURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrationStateURL.path))
    }

    func testAtomicReplacePreservesPermissions() throws {
        try writeFixture(["ssl": ["ech_enabled": true]], permissions: 0o640)
        let before = try permissions(of: localStateURL)
        try makeManager().configure()
        XCTAssertEqual(try permissions(of: localStateURL), before)
    }

    private func makeManager(
        writer: ChromeDNSLocalStateWriting = POSIXChromeDNSLocalStateWriter()
    ) -> ChromeECHManager {
        ChromeECHManager(
            localStateURL: localStateURL,
            integrationStateURL: integrationStateURL,
            applicationController: chromeController,
            localStateWriter: writer,
            policyProvider: policyProvider
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
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: localStateURL)
            ) as? [String: Any]
        )
    }

    private func readIntegrationRecord() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: integrationStateURL)
            ) as? [String: Any]
        )
    }

    private func permissions(of url: URL) throws -> mode_t {
        var info = stat()
        XCTAssertEqual(Darwin.lstat(url.path, &info), 0)
        return info.st_mode & 0o7777
    }
}

private final class ECHFakeChromeApplicationController: ChromeApplicationControlling {
    var running = false

    func isChromeRunning() -> Bool { running }
    func requestChromeTermination() -> Bool { true }
    func reopenChrome() throws {}
}

private final class ECHSequencedChromeApplicationController: ChromeApplicationControlling {
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

    func requestChromeTermination() -> Bool { true }
    func reopenChrome() throws {}
}

private final class FakeChromeECHPolicyProvider: ChromeECHPolicyProviding {
    var state: ChromeECHManagedPolicyState

    init(state: ChromeECHManagedPolicyState) {
        self.state = state
    }

    func managedPolicyState() -> ChromeECHManagedPolicyState { state }
}

private final class ECHRecordingLocalStateWriter: ChromeDNSLocalStateWriting {
    private(set) var writeCount = 0

    func replaceFile(
        at url: URL,
        with data: Data,
        preserving metadata: ChromeDNSFileMetadata
    ) throws {
        writeCount += 1
    }
}

private final class ECHFailingLocalStateWriter: ChromeDNSLocalStateWriting {
    func replaceFile(
        at url: URL,
        with data: Data,
        preserving metadata: ChromeDNSFileMetadata
    ) throws {
        throw ChromeECHIntegrationError.fileOperation("synthetic write failure")
    }
}
