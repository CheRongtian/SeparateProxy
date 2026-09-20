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

    func testPIDWriteFailureTerminatesLaunchedProcessAndCleansUp() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        store.writePIDError = FakeError.writePIDFailed
        let processes = FakeProcessManager()
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(configurationData: data, redacting: [])) {
            error in
            guard let fakeError = error as? FakeError,
                  case .writePIDFailed = fakeError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(processes.launchCount, 1)
        XCTAssertEqual(processes.lastLaunchedProcess?.terminateCount, 1)
        XCTAssertEqual(processes.waitForExitCalls, [processes.nextPID])
        XCTAssertNil(store.pid)
        XCTAssertNil(store.activeConfigDigest)
        XCTAssertNil(store.configData)
    }

    func testPIDWriteFailureWithTerminationTimeoutPreservesUnresolvedProcess() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        store.writePIDError = FakeError.writePIDFailed
        let processes = FakeProcessManager()
        processes.waitForExitResult = false
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(configurationData: data, redacting: [])) {
            error in
            guard case SingBoxControllerError.unresolvedLifecycle = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(processes.launchCount, 1)
        XCTAssertEqual(processes.lastLaunchedProcess?.terminateCount, 1)
        XCTAssertTrue(processes.lastLaunchedProcess?.isRunning == true)
        XCTAssertEqual(store.configData, data)
        XCTAssertNil(store.pid)
    }

    func testUnresolvedPIDWriteFailureBlocksSecondLaunch() throws {
        let firstData = try chromeConfigurationData()
        let secondData = try chromeAndGitConfigurationData()
        let store = FakeRuntimeStore()
        store.writePIDError = FakeError.writePIDFailed
        let processes = FakeProcessManager()
        processes.waitForExitResult = false
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(
            configurationData: firstData,
            redacting: []
        ))
        XCTAssertThrowsError(try controller.start(
            configurationData: secondData,
            redacting: []
        )) { error in
            guard case SingBoxControllerError.unresolvedLifecycle = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(processes.launchCount, 1)
        XCTAssertEqual(store.configData, firstData)
    }

    func testStopTerminatesUnresolvedProcessWithoutPIDFile() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        store.writePIDError = FakeError.writePIDFailed
        let processes = FakeProcessManager()
        processes.waitForExitResult = false
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(configurationData: data, redacting: []))
        processes.waitForExitResult = true
        try controller.stop()

        XCTAssertEqual(processes.launchCount, 1)
        XCTAssertEqual(processes.waitForExitCalls, [processes.nextPID, processes.nextPID])
        XCTAssertFalse(processes.lastLaunchedProcess?.isRunning == true)
        XCTAssertNil(store.pid)
        XCTAssertNil(store.activeConfigDigest)
        XCTAssertNil(store.configData)
    }

    func testStateUsesUnresolvedInMemoryProcessWithoutPIDFile() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        store.writePIDError = FakeError.writePIDFailed
        let processes = FakeProcessManager()
        processes.waitForExitResult = false
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(configurationData: data, redacting: []))
        XCTAssertEqual(try controller.state(), .running)

        processes.lastLaunchedProcess?.isRunning = false
        XCTAssertEqual(try controller.state(), .stopped)
        XCTAssertNil(store.configData)
    }

    func testDigestWriteFailureTerminatesProcessAndRemovesDurablePID() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        store.writeActiveConfigDigestError = FakeError.digestWriteFailed
        let processes = FakeProcessManager()
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(configurationData: data, redacting: [])) {
            error in
            guard let fakeError = error as? FakeError,
                  case .digestWriteFailed = fakeError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(processes.waitForExitCalls, [processes.nextPID])
        XCTAssertEqual(processes.lastLaunchedProcess?.terminateCount, 1)
        XCTAssertNil(store.pid)
        XCTAssertNil(store.activeConfigDigest)
        XCTAssertNil(store.configData)
    }

    func testDigestWriteFailureWithTerminationTimeoutPreservesDurablePID() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        store.writeActiveConfigDigestError = FakeError.digestWriteFailed
        let processes = FakeProcessManager()
        processes.waitForExitResult = false
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(configurationData: data, redacting: [])) {
            error in
            guard case SingBoxControllerError.unresolvedLifecycle = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(store.pid, processes.nextPID)
        XCTAssertNil(store.activeConfigDigest)
        XCTAssertEqual(store.configData, data)
    }

    func testFinalProcessVerificationFailureDoesNotReturnStartSuccess() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        processes.matchesExpectedProcessOverride = false
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(configurationData: data, redacting: [])) {
            error in
            guard case SingBoxControllerError.unresolvedLifecycle = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(processes.launchCount, 1)
        XCTAssertEqual(store.pid, processes.nextPID)
        XCTAssertEqual(
            store.activeConfigDigest,
            SingBoxController.configurationDigest(for: data)
        )
        XCTAssertEqual(processes.lastLaunchedProcess?.terminateCount, 0)
    }

    func testFinalVerificationMismatchStopFailsClosedAndBlocksSecondLaunch() throws {
        let firstData = try chromeConfigurationData()
        let secondData = try chromeAndGitConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        processes.matchesExpectedProcessOverride = false
        processes.managedProcessStopsWhenWaitSucceeds = false
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(
            configurationData: firstData,
            redacting: []
        ))
        let removePIDCount = store.removePIDCount
        let removeDigestCount = store.removeActiveConfigDigestCount
        let removeConfigCount = store.removeConfigCount

        XCTAssertThrowsError(try controller.stop()) { error in
            guard case SingBoxControllerError.unresolvedLifecycle = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertTrue(processes.lastLaunchedProcess?.isRunning == true)
        XCTAssertEqual(store.pid, processes.nextPID)
        XCTAssertEqual(store.configData, firstData)
        XCTAssertNotNil(store.activeConfigDigest)
        XCTAssertEqual(store.removePIDCount, removePIDCount)
        XCTAssertEqual(store.removeActiveConfigDigestCount, removeDigestCount)
        XCTAssertEqual(store.removeConfigCount, removeConfigCount)

        XCTAssertThrowsError(try controller.start(
            configurationData: secondData,
            redacting: []
        )) { error in
            guard case SingBoxControllerError.unresolvedLifecycle = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(processes.launchCount, 1)
        XCTAssertEqual(store.configData, firstData)
    }

    func testFinalVerificationMismatchStopCleansUpAfterConfirmedExitAndAllowsRestart() throws {
        let firstData = try chromeConfigurationData()
        let secondData = try chromeAndGitConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        processes.matchesExpectedProcessOverride = false
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(
            configurationData: firstData,
            redacting: []
        ))
        try controller.stop()

        XCTAssertFalse(processes.lastLaunchedProcess?.isRunning == true)
        XCTAssertNil(store.pid)
        XCTAssertNil(store.activeConfigDigest)
        XCTAssertNil(store.configData)

        processes.matchesExpectedProcessOverride = nil
        XCTAssertEqual(
            try controller.start(configurationData: secondData, redacting: []),
            processes.nextPID
        )
        XCTAssertEqual(processes.launchCount, 2)
    }

    func testManagedWaitSuccessDoesNotConfirmExitWhileProcessIsStillRunning() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        processes.matchesExpectedProcessOverride = false
        processes.waitForExitResult = true
        processes.managedProcessStopsWhenWaitSucceeds = false
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(configurationData: data, redacting: []))
        XCTAssertThrowsError(try controller.stop()) { error in
            guard case SingBoxControllerError.unresolvedLifecycle = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(processes.managedProcessWaitForExitCalls, [processes.nextPID])
        XCTAssertTrue(processes.lastLaunchedProcess?.isRunning == true)
        XCTAssertEqual(processes.lastLaunchedProcess?.terminateCount, 1)
        XCTAssertEqual(store.configData, data)
    }

    func testUnresolvedStopCleansUpProcessAlreadyConfirmedExited() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        processes.matchesExpectedProcessOverride = false
        let controller = makeController(store: store, processes: processes)

        XCTAssertThrowsError(try controller.start(configurationData: data, redacting: []))
        processes.lastLaunchedProcess?.isRunning = false
        try controller.stop()

        XCTAssertEqual(processes.managedProcessWaitForExitCalls, [])
        XCTAssertNil(store.pid)
        XCTAssertNil(store.activeConfigDigest)
        XCTAssertNil(store.configData)
    }

    func testFinalProcessVerificationSuccessReturnsLaunchedPID() throws {
        let data = try chromeConfigurationData()
        let store = FakeRuntimeStore()
        let processes = FakeProcessManager()
        let controller = makeController(store: store, processes: processes)

        let pid = try controller.start(configurationData: data, redacting: [])

        XCTAssertEqual(pid, processes.nextPID)
        XCTAssertEqual(processes.launchCount, 1)
        XCTAssertEqual(store.pid, processes.nextPID)
        XCTAssertEqual(
            store.activeConfigDigest,
            SingBoxController.configurationDigest(for: data)
        )
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

    func testSecureRuntimeStoreRejectsSymlinkRuntimeDirectory() throws {
        let baseURL = try makeTemporaryRuntimeBase()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let targetURL = baseURL.appendingPathComponent("runtime-target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: baseURL.appendingPathComponent("runtime"),
            withDestinationURL: targetURL
        )
        let store = SecureRuntimeStore(baseURL: baseURL, expectedOwner: getuid())

        XCTAssertThrowsError(try store.prepare()) { error in
            guard case SecureRuntimeStoreError.invalidDirectory = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSecureRuntimeStoreRejectsSymlinkMetadataFile() throws {
        let baseURL = try makeTemporaryRuntimeBase()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = SecureRuntimeStore(baseURL: baseURL, expectedOwner: getuid())
        try store.prepare()
        let targetURL = baseURL.appendingPathComponent("outside-pid")
        try Data("123\n".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: store.pidURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(try store.readPID()) { error in
            guard case SecureRuntimeStoreError.invalidFile = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSecureRuntimeStoreRejectsNonRegularMetadataFile() throws {
        let baseURL = try makeTemporaryRuntimeBase()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = SecureRuntimeStore(baseURL: baseURL, expectedOwner: getuid())
        try store.prepare()
        try FileManager.default.createDirectory(
            at: store.pidURL,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try store.readPID()) { error in
            guard case SecureRuntimeStoreError.invalidFile = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSecureRuntimeStoreRejectsInsecureDirectoryMode() throws {
        let baseURL = try makeTemporaryRuntimeBase()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        XCTAssertEqual(Darwin.chmod(baseURL.path, 0o777), 0)
        let store = SecureRuntimeStore(baseURL: baseURL, expectedOwner: getuid())

        XCTAssertThrowsError(try store.prepare()) { error in
            guard case SecureRuntimeStoreError.invalidDirectory = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSecureRuntimeStoreRejectsUnexpectedOwner() throws {
        let baseURL = try makeTemporaryRuntimeBase()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let unexpectedOwner: uid_t = getuid() == 0 ? 1 : 0
        let store = SecureRuntimeStore(baseURL: baseURL, expectedOwner: unexpectedOwner)

        XCTAssertThrowsError(try store.prepare()) { error in
            guard case SecureRuntimeStoreError.invalidDirectory = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSecureRuntimeStoreRejectsMalformedAndEmptyPID() throws {
        for contents in ["not-a-pid", ""] {
            let baseURL = try makeTemporaryRuntimeBase()
            defer { try? FileManager.default.removeItem(at: baseURL) }
            let store = SecureRuntimeStore(baseURL: baseURL, expectedOwner: getuid())
            try store.prepare()
            try Data(contents.utf8).write(to: store.pidURL)

            XCTAssertThrowsError(try store.readPID()) { error in
                guard case SecureRuntimeStoreError.invalidPID = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testSecureRuntimeStoreRejectsOversizedMetadata() throws {
        let baseURL = try makeTemporaryRuntimeBase()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = SecureRuntimeStore(baseURL: baseURL, expectedOwner: getuid())
        try store.prepare()
        try Data(repeating: 0x31, count: 4_097).write(to: store.pidURL)

        XCTAssertThrowsError(try store.readPID()) { error in
            guard case SecureRuntimeStoreError.invalidFile = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSecureRuntimeStoreTreatsMalformedDigestAsMissing() throws {
        let baseURL = try makeTemporaryRuntimeBase()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = SecureRuntimeStore(baseURL: baseURL, expectedOwner: getuid())
        try store.prepare()
        try Data("not-a-sha256-digest".utf8).write(to: store.activeConfigDigestURL)

        XCTAssertNil(try store.readActiveConfigDigest())
    }

    private func makeTemporaryRuntimeBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-RuntimeStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
    case digestWriteFailed
    case launchFailed
    case writePIDFailed
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
    var writePIDError: Error?
    var writeActiveConfigDigestError: Error?
    var removeConfigCount = 0
    var removePIDCount = 0
    var removeActiveConfigDigestCount = 0

    func writeConfig(_ data: Data) throws {
        configData = data
    }

    func writePID(_ pid: pid_t) throws {
        if let writePIDError {
            throw writePIDError
        }
        self.pid = pid
    }

    func readPID() throws -> pid_t? {
        pid
    }

    func writeActiveConfigDigest(_ digest: String) throws {
        if let writeActiveConfigDigestError {
            throw writeActiveConfigDigestError
        }
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
    }
}

private final class FakeProcessManager: SingBoxProcessManaging {
    var checkStatus: Int32 = 0
    var checkOutput = ""
    var verifiedPIDs: Set<pid_t> = []
    var nextPID: pid_t = 200
    var waitForExitResult = true
    var managedProcessStopsWhenWaitSucceeds = true
    var launchError: Error?
    var matchesExpectedProcessOverride: Bool?
    private(set) var launchCount = 0
    private(set) var terminateCalls: [pid_t] = []
    private(set) var waitForExitCalls: [pid_t] = []
    private(set) var managedProcessWaitForExitCalls: [pid_t] = []
    private(set) var lastLaunchedProcess: FakeManagedProcess?

    func checkConfiguration(
        executableURL: URL,
        configURL: URL
    ) throws -> (status: Int32, output: String) {
        (checkStatus, checkOutput)
    }

    func matchesExpectedProcess(pid: pid_t, expectedCommand: String) throws -> Bool {
        if let matchesExpectedProcessOverride {
            return matchesExpectedProcessOverride
        }
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
        lastLaunchedProcess = process
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
            if lastLaunchedProcess?.processIdentifier == pid {
                lastLaunchedProcess?.isRunning = false
            }
        }
        return waitForExitResult
    }

    func waitForExit(process: SingBoxManagedProcess) throws -> Bool {
        waitForExitCalls.append(process.processIdentifier)
        managedProcessWaitForExitCalls.append(process.processIdentifier)
        if waitForExitResult, managedProcessStopsWhenWaitSucceeds {
            verifiedPIDs.remove(process.processIdentifier)
            if let fakeProcess = process as? FakeManagedProcess {
                fakeProcess.isRunning = false
            }
        }
        return waitForExitResult
    }
}
