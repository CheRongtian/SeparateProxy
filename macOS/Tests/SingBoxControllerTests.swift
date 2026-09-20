import Darwin
import Foundation
import XCTest
@testable import SeparateProxyCore

final class SingBoxControllerTests: XCTestCase {
    private let outline = OutlineAccessKey(
        server: "192.0.2.1",
        serverPort: 8388,
        method: "aes-256-gcm",
        password: "test-only-password"
    )
    private let gitInstallation = AppleGitInstallation(
        developerDirectoryPath: "/Applications/Xcode.app/Contents/Developer",
        gitExecutablePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        httpsHelperEntryPath: "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-remote-https",
        canonicalHTTPHelperPath: "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-remote-http"
    )

    func testSameConfigurationReusesVerifiedLivePID() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        prepareRunningSession(
            store: store,
            processes: processes,
            pid: 101,
            configurationData: data
        )
        let controller = makeController(store: store, processes: processes)

        let returnedPID = try controller.start(configurationData: data, redacting: [])

        XCTAssertEqual(returnedPID, 101)
        XCTAssertEqual(processes.terminateCalls, [])
        XCTAssertEqual(processes.launchCount, 0)
        XCTAssertEqual(
            store.activeConfigDigest,
            SingBoxController.configurationDigest(for: data)
        )
        XCTAssertEqual(store.removePIDCount, 0)
        XCTAssertEqual(store.removeActiveConfigDigestCount, 0)
        XCTAssertEqual(store.removeConfigCount, 0)
    }

    func testChangedRealConfigurationRestartsAndPersistsNewIdentity() throws {
        let oldData = try chromeConfigurationData()
        let newData = try chromeAndGitConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        processes.nextPID = 202
        prepareRunningSession(
            store: store,
            processes: processes,
            pid: 101,
            configurationData: oldData
        )
        let controller = makeController(store: store, processes: processes)

        let returnedPID = try controller.start(configurationData: newData, redacting: [])

        XCTAssertEqual(returnedPID, 202)
        XCTAssertEqual(processes.terminateCalls, [101])
        XCTAssertEqual(processes.waitForExitCalls, [101])
        XCTAssertEqual(processes.launchCount, 1)
        XCTAssertEqual(store.pid, 202)
        XCTAssertEqual(
            store.activeConfigDigest,
            SingBoxController.configurationDigest(for: newData)
        )
        XCTAssertNotEqual(
            SingBoxController.configurationDigest(for: oldData),
            SingBoxController.configurationDigest(for: newData)
        )
    }

    func testMissingActiveDigestRestartsVerifiedUpgradeSession() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        store.pid = 101
        store.configData = data
        processes.verifiedPIDs = [101]
        processes.nextPID = 202
        let controller = makeController(store: store, processes: processes)

        let returnedPID = try controller.start(configurationData: data, redacting: [])

        XCTAssertEqual(returnedPID, 202)
        XCTAssertEqual(processes.terminateCalls, [101])
        XCTAssertEqual(processes.launchCount, 1)
        XCTAssertEqual(
            store.activeConfigDigest,
            SingBoxController.configurationDigest(for: data)
        )
    }

    func testMalformedOrUnreadableActiveDigestRestartsVerifiedProcess() throws {
        let data = try chromeConfigurationData()

        for digestState in [FakeRuntimeStore.DigestState.malformed, .unreadable] {
            let store = FakeRuntimeStore()
            let processes = FakeProcessManager()
            store.pid = 101
            store.configData = data
            store.digestState = digestState
            processes.verifiedPIDs = [101]
            processes.nextPID = 202
            let controller = makeController(store: store, processes: processes)

            let returnedPID = try controller.start(configurationData: data, redacting: [])

            XCTAssertEqual(returnedPID, 202)
            XCTAssertEqual(processes.terminateCalls, [101])
            XCTAssertEqual(processes.launchCount, 1)
            XCTAssertEqual(
                store.activeConfigDigest,
                SingBoxController.configurationDigest(for: data)
            )
        }
    }

    func testDeadPIDClearsStaleIdentityAndLaunchesNewProcess() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        store.pid = 101
        store.activeConfigDigest = SingBoxController.configurationDigest(for: data)
        processes.nextPID = 202
        let controller = makeController(store: store, processes: processes)

        let returnedPID = try controller.start(configurationData: data, redacting: [])

        XCTAssertEqual(returnedPID, 202)
        XCTAssertEqual(processes.terminateCalls, [])
        XCTAssertEqual(processes.launchCount, 1)
        XCTAssertGreaterThanOrEqual(store.removePIDCount, 1)
        XCTAssertGreaterThanOrEqual(store.removeActiveConfigDigestCount, 1)
        XCTAssertEqual(store.pid, 202)
    }

    func testIdentityMismatchIsNeverTerminated() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        store.pid = 303
        store.activeConfigDigest = SingBoxController.configurationDigest(for: data)
        processes.nextPID = 404
        let controller = makeController(store: store, processes: processes)

        let returnedPID = try controller.start(configurationData: data, redacting: [])

        XCTAssertEqual(returnedPID, 404)
        XCTAssertEqual(processes.terminateCalls, [])
        XCTAssertFalse(processes.waitForExitCalls.contains(303))
        XCTAssertEqual(processes.launchCount, 1)
    }

    func testConfigurationCheckFailurePreservesHealthyRunningProcess() throws {
        let oldData = try chromeConfigurationData()
        let newData = try chromeAndGitConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        prepareRunningSession(
            store: store,
            processes: processes,
            pid: 101,
            configurationData: oldData
        )
        processes.checkStatus = 1
        processes.checkOutput = "invalid password test-only-password"
        let oldDigest = try XCTUnwrap(store.activeConfigDigest)
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(
            configurationData: newData,
            redacting: ["test-only-password"]
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "sing-box configuration check failed: invalid password <redacted>"
            )
        }
        XCTAssertEqual(processes.terminateCalls, [])
        XCTAssertEqual(processes.launchCount, 0)
        XCTAssertEqual(store.pid, 101)
        XCTAssertEqual(store.activeConfigDigest, oldDigest)
        XCTAssertTrue(processes.verifiedPIDs.contains(101))
    }

    func testChangedConfigurationTerminationTimeoutDoesNotLaunchSecondProcess() throws {
        let oldData = try chromeConfigurationData()
        let newData = try chromeAndGitConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        prepareRunningSession(
            store: store,
            processes: processes,
            pid: 101,
            configurationData: oldData
        )
        processes.waitForExitResult = false
        let oldDigest = try XCTUnwrap(store.activeConfigDigest)
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(
            configurationData: newData,
            redacting: []
        )) { error in
            guard case SingBoxControllerError.stopTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(processes.terminateCalls, [101])
        XCTAssertEqual(processes.launchCount, 0)
        XCTAssertEqual(store.pid, 101)
        XCTAssertEqual(store.activeConfigDigest, oldDigest)
    }

    func testChangedConfigurationLaunchFailureLeavesNoFalseActiveIdentity() throws {
        let oldData = try chromeConfigurationData()
        let newData = try chromeAndGitConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        prepareRunningSession(
            store: store,
            processes: processes,
            pid: 101,
            configurationData: oldData
        )
        processes.launchError = FakeError.launchFailed
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(
            configurationData: newData,
            redacting: []
        ))
        XCTAssertEqual(processes.terminateCalls, [101])
        XCTAssertEqual(processes.launchCount, 1)
        XCTAssertNil(store.pid)
        XCTAssertNil(store.activeConfigDigest)
        XCTAssertNil(store.configData)
    }

    func testStopCleansPIDConfigAndActiveDigest() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        prepareRunningSession(
            store: store,
            processes: processes,
            pid: 101,
            configurationData: data
        )
        let controller = makeController(store: store, processes: processes)

        try controller.stop()

        XCTAssertEqual(processes.terminateCalls, [101])
        XCTAssertNil(store.pid)
        XCTAssertNil(store.configData)
        XCTAssertNil(store.activeConfigDigest)
    }

    func testSameLogicalConfigurationProducesStableExactBytesAndDigest() throws {
        let first = try chromeAndGitConfigurationData()
        let second = try chromeAndGitConfigurationData()

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            SingBoxController.configurationDigest(for: first),
            SingBoxController.configurationDigest(for: second)
        )
    }

    func testSecureRuntimeStoreValidatesDigestContentAndPermissions() throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-Controller-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = SecureRuntimeStore(baseURL: baseURL, expectedOwner: getuid())
        let digest = String(repeating: "a", count: 64)

        try store.writeActiveConfigDigest(digest)

        XCTAssertEqual(try store.readActiveConfigDigest(), digest)
        var information = stat()
        XCTAssertEqual(lstat(store.activeConfigDigestURL.path, &information), 0)
        XCTAssertEqual(information.st_mode & 0o777, 0o600)

        try Data("malformed".utf8).write(to: store.activeConfigDigestURL, options: .atomic)
        XCTAssertNil(try store.readActiveConfigDigest())
        try store.removeActiveConfigDigest()
        XCTAssertNil(try store.readActiveConfigDigest())
    }

    private func makeController(
        store: FakeRuntimeStore,
        processes: FakeProcessManager
    ) -> SingBoxController {
        SingBoxController(
            runtimeStore: store,
            processManager: processes,
            singBoxURL: URL(fileURLWithPath: "/Test/SeparateProxy/sing-box")
        )
    }

    private func prepareRunningSession(
        store: FakeRuntimeStore,
        processes: FakeProcessManager,
        pid: pid_t,
        configurationData: Data
    ) {
        store.pid = pid
        store.configData = configurationData
        store.activeConfigDigest = SingBoxController.configurationDigest(
            for: configurationData
        )
        processes.verifiedPIDs = [pid]
    }

    private func chromeConfigurationData() throws -> Data {
        try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app"
        ).encodedJSON()
    }

    private func chromeAndGitConfigurationData() throws -> Data {
        try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            gitInstallation: gitInstallation
        ).encodedJSON()
    }
}

private enum FakeError: Error {
    case digestUnreadable
    case launchFailed
}

private final class FakeRuntimeStore: SingBoxRuntimeStoring {
    enum DigestState {
        case validOrMissing
        case malformed
        case unreadable
    }

    let configURL = URL(fileURLWithPath: "/Test/SeparateProxy/runtime/config.json")
    var configData: Data?
    var pid: pid_t?
    var activeConfigDigest: String?
    var digestState = DigestState.validOrMissing
    var removeConfigCount = 0
    var removePIDCount = 0
    var removeActiveConfigDigestCount = 0

    func writeConfig(_ data: Data) throws {
        configData = data
    }

    func writePID(_ pid: pid_t) throws {
        self.pid = pid
    }

    func readPID() throws -> pid_t? {
        pid
    }

    func writeActiveConfigDigest(_ digest: String) throws {
        activeConfigDigest = digest
        digestState = .validOrMissing
    }

    func readActiveConfigDigest() throws -> String? {
        switch digestState {
        case .validOrMissing:
            return activeConfigDigest
        case .malformed:
            return nil
        case .unreadable:
            throw FakeError.digestUnreadable
        }
    }

    func openLogForReplacement() throws -> FileHandle {
        try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null"))
    }

    func removeConfig() throws {
        removeConfigCount += 1
        configData = nil
    }

    func removePID() throws {
        removePIDCount += 1
        pid = nil
    }

    func removeActiveConfigDigest() throws {
        removeActiveConfigDigestCount += 1
        activeConfigDigest = nil
        digestState = .validOrMissing
    }
}

private final class FakeManagedProcess: SingBoxManagedProcess {
    let processIdentifier: pid_t
    var isRunning: Bool
    private(set) var terminateCount = 0

    init(processIdentifier: pid_t, isRunning: Bool = true) {
        self.processIdentifier = processIdentifier
        self.isRunning = isRunning
    }

    func terminate() {
        terminateCount += 1
        isRunning = false
    }
}

private final class FakeProcessManager: SingBoxProcessManaging {
    var checkStatus: Int32 = 0
    var checkOutput = ""
    var verifiedPIDs: Set<pid_t> = []
    var nextPID: pid_t = 200
    var waitForExitResult = true
    var launchError: Error?
    private(set) var launchCount = 0
    private(set) var terminateCalls: [pid_t] = []
    private(set) var waitForExitCalls: [pid_t] = []

    func checkConfiguration(
        executableURL: URL,
        configURL: URL
    ) throws -> (status: Int32, output: String) {
        (checkStatus, checkOutput)
    }

    func matchesExpectedProcess(pid: pid_t, expectedCommand: String) throws -> Bool {
        verifiedPIDs.contains(pid)
    }

    func launch(
        executableURL: URL,
        configURL: URL,
        logHandle: FileHandle
    ) throws -> SingBoxManagedProcess {
        launchCount += 1
        if let launchError {
            throw launchError
        }
        let process = FakeManagedProcess(processIdentifier: nextPID)
        verifiedPIDs.insert(nextPID)
        return process
    }

    func terminate(pid: pid_t) throws {
        terminateCalls.append(pid)
    }

    func waitForExit(pid: pid_t, expectedCommand: String) throws -> Bool {
        waitForExitCalls.append(pid)
        if waitForExitResult {
            verifiedPIDs.remove(pid)
        }
        return waitForExitResult
    }
}
