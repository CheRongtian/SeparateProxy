import CryptoKit
import Darwin
import Foundation
import SeparateProxyCore

enum SingBoxControllerError: LocalizedError {
    case executablePathUnavailable
    case bundledBinaryMissing
    case configurationCheckFailed(String)
    case launchFailed(String)
    case recordedProcessMismatch
    case stopTimedOut

    var errorDescription: String? {
        switch self {
        case .executablePathUnavailable:
            return "The privileged helper executable path is unavailable."
        case .bundledBinaryMissing:
            return "The bundled patched sing-box executable is missing."
        case let .configurationCheckFailed(message):
            return "sing-box configuration check failed: \(message)"
        case let .launchFailed(message):
            return "sing-box failed to start: \(message)"
        case .recordedProcessMismatch:
            return "The recorded PID does not match this helper's sing-box process. No process was stopped."
        case .stopTimedOut:
            return "sing-box did not stop within five seconds."
        }
    }
}

protocol SingBoxRuntimeStoring: AnyObject {
    var configURL: URL { get }

    func writeConfig(_ data: Data) throws
    func writePID(_ pid: pid_t) throws
    func readPID() throws -> pid_t?
    func writeActiveConfigDigest(_ digest: String) throws
    func readActiveConfigDigest() throws -> String?
    func openLogForReplacement() throws -> FileHandle
    func removeConfig() throws
    func removePID() throws
    func removeActiveConfigDigest() throws
}

extension SecureRuntimeStore: SingBoxRuntimeStoring {}

protocol SingBoxManagedProcess: AnyObject {
    var processIdentifier: pid_t { get }
    var isRunning: Bool { get }

    func terminate()
}

protocol SingBoxProcessManaging: AnyObject {
    func checkConfiguration(
        executableURL: URL,
        configURL: URL
    ) throws -> (status: Int32, output: String)
    func matchesExpectedProcess(pid: pid_t, expectedCommand: String) throws -> Bool
    func launch(
        executableURL: URL,
        configURL: URL,
        logHandle: FileHandle
    ) throws -> SingBoxManagedProcess
    func terminate(pid: pid_t) throws
    func waitForExit(pid: pid_t, expectedCommand: String) throws -> Bool
}

private final class FoundationSingBoxProcess: SingBoxManagedProcess {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    var processIdentifier: pid_t {
        process.processIdentifier
    }

    var isRunning: Bool {
        process.isRunning
    }

    func terminate() {
        process.terminate()
    }
}

private final class SystemSingBoxProcessManager: SingBoxProcessManaging {
    func checkConfiguration(
        executableURL: URL,
        configURL: URL
    ) throws -> (status: Int32, output: String) {
        try runAndCapture(
            executableURL: executableURL,
            arguments: ["check", "-c", configURL.path]
        )
    }

    func matchesExpectedProcess(pid: pid_t, expectedCommand: String) throws -> Bool {
        let uidResult = try runAndCapture(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(pid)", "-o", "uid="]
        )
        guard uidResult.status == 0,
              uidResult.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else {
            return false
        }

        let commandResult = try runAndCapture(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ww", "-p", "\(pid)", "-o", "command="]
        )
        return commandResult.status == 0
            && commandResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                == expectedCommand
    }

    func launch(
        executableURL: URL,
        configURL: URL,
        logHandle: FileHandle
    ) throws -> SingBoxManagedProcess {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["run", "-c", configURL.path]
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
            guard process.isRunning else {
                throw SingBoxControllerError.launchFailed("the process exited immediately")
            }
            return FoundationSingBoxProcess(process)
        } catch let error as SingBoxControllerError {
            if process.isRunning {
                process.terminate()
            }
            throw error
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw SingBoxControllerError.launchFailed(error.localizedDescription)
        }
    }

    func terminate(pid: pid_t) throws {
        guard Darwin.kill(pid, SIGTERM) == 0 else {
            if errno == ESRCH {
                return
            }
            throw SecureRuntimeStoreError.systemCall("terminate sing-box", errno)
        }
    }

    func waitForExit(pid: pid_t, expectedCommand: String) throws -> Bool {
        for _ in 0..<50 {
            if try !matchesExpectedProcess(pid: pid, expectedCommand: expectedCommand) {
                return true
            }
            usleep(100_000)
        }
        return false
    }

    private func runAndCapture(
        executableURL: URL,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data.prefix(8_192), encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            throw SingBoxControllerError.launchFailed(error.localizedDescription)
        }
    }
}

final class SingBoxController {
    private let runtimeStore: SingBoxRuntimeStoring
    private let processManager: SingBoxProcessManaging
    private let singBoxURL: URL
    private var launchedProcess: SingBoxManagedProcess?

    convenience init(runtimeStore: SecureRuntimeStore) throws {
        let helperURL = try Self.currentExecutableURL()
        let singBoxURL = helperURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("sing-box", isDirectory: false)

        guard FileManager.default.isExecutableFile(atPath: singBoxURL.path) else {
            throw SingBoxControllerError.bundledBinaryMissing
        }
        self.init(
            runtimeStore: runtimeStore,
            processManager: SystemSingBoxProcessManager(),
            singBoxURL: singBoxURL
        )
    }

    init(
        runtimeStore: SingBoxRuntimeStoring,
        processManager: SingBoxProcessManaging,
        singBoxURL: URL
    ) {
        self.runtimeStore = runtimeStore
        self.processManager = processManager
        self.singBoxURL = singBoxURL
    }

    private static func currentExecutableURL() throws -> URL {
        var bufferSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &bufferSize)
        guard bufferSize > 0 else {
            throw SingBoxControllerError.executablePathUnavailable
        }

        var buffer = [CChar](repeating: 0, count: Int(bufferSize))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &bufferSize)
        }
        guard result == 0 else {
            throw SingBoxControllerError.executablePathUnavailable
        }

        return buffer.withUnsafeBufferPointer { pointer in
            URL(
                fileURLWithFileSystemRepresentation: pointer.baseAddress!,
                isDirectory: false,
                relativeTo: nil
            )
        }
        .standardizedFileURL
    }

    static func configurationDigest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func state() throws -> ProxyState {
        if let process = launchedProcess, process.isRunning {
            return .running
        }
        guard let pid = try runtimeStore.readPID() else {
            return .stopped
        }
        return try processManager.matchesExpectedProcess(
            pid: pid,
            expectedCommand: expectedCommand
        ) ? .running : .stopped
    }

    func start(configurationData: Data, redacting secrets: [String]) throws -> pid_t {
        try runtimeStore.writeConfig(configurationData)
        do {
            try checkConfiguration(redacting: secrets)
            return try startCheckedConfiguration(
                digest: Self.configurationDigest(for: configurationData)
            )
        } catch {
            try? runtimeStore.removeConfig()
            throw error
        }
    }

    func stop() throws {
        guard let pid = try runtimeStore.readPID() else {
            try runtimeStore.removeConfig()
            try runtimeStore.removeActiveConfigDigest()
            return
        }
        guard try processManager.matchesExpectedProcess(
            pid: pid,
            expectedCommand: expectedCommand
        ) else {
            throw SingBoxControllerError.recordedProcessMismatch
        }
        try terminateVerifiedRunningProcess(pid: pid, removeConfig: true)
    }

    private var expectedCommand: String {
        "\(singBoxURL.path) run -c \(runtimeStore.configURL.path)"
    }

    private func checkConfiguration(redacting secrets: [String]) throws {
        let result = try processManager.checkConfiguration(
            executableURL: singBoxURL,
            configURL: runtimeStore.configURL
        )
        guard result.status == 0 else {
            let sanitized = sanitize(result.output, secrets: secrets)
            throw SingBoxControllerError.configurationCheckFailed(
                sanitized.isEmpty ? "unknown validation error" : sanitized
            )
        }
    }

    private func startCheckedConfiguration(digest: String) throws -> pid_t {
        if let pid = try runtimeStore.readPID() {
            if try processManager.matchesExpectedProcess(
                pid: pid,
                expectedCommand: expectedCommand
            ) {
                let activeDigest = try? runtimeStore.readActiveConfigDigest()
                if activeDigest == digest {
                    return pid
                }
                try terminateVerifiedRunningProcess(pid: pid, removeConfig: false)
            } else {
                try? runtimeStore.removePID()
                try? runtimeStore.removeActiveConfigDigest()
            }
        } else {
            try? runtimeStore.removeActiveConfigDigest()
        }

        return try launchCheckedConfiguration(digest: digest)
    }

    private func terminateVerifiedRunningProcess(
        pid: pid_t,
        removeConfig: Bool
    ) throws {
        guard try processManager.matchesExpectedProcess(
            pid: pid,
            expectedCommand: expectedCommand
        ) else {
            throw SingBoxControllerError.recordedProcessMismatch
        }
        try processManager.terminate(pid: pid)
        guard try processManager.waitForExit(
            pid: pid,
            expectedCommand: expectedCommand
        ) else {
            throw SingBoxControllerError.stopTimedOut
        }

        try runtimeStore.removePID()
        try runtimeStore.removeActiveConfigDigest()
        if removeConfig {
            try runtimeStore.removeConfig()
        }
        launchedProcess = nil
    }

    private func launchCheckedConfiguration(digest: String) throws -> pid_t {
        try? runtimeStore.removePID()
        try? runtimeStore.removeActiveConfigDigest()

        let logHandle = try runtimeStore.openLogForReplacement()
        let process = try processManager.launch(
            executableURL: singBoxURL,
            configURL: runtimeStore.configURL,
            logHandle: logHandle
        )
        guard process.isRunning else {
            throw SingBoxControllerError.launchFailed("the process exited immediately")
        }

        do {
            try runtimeStore.writePID(process.processIdentifier)
            try runtimeStore.writeActiveConfigDigest(digest)
            launchedProcess = process
            return process.processIdentifier
        } catch {
            if process.isRunning {
                process.terminate()
                let exited = (try? processManager.waitForExit(
                    pid: process.processIdentifier,
                    expectedCommand: expectedCommand
                )) == true
                if exited {
                    try? runtimeStore.removePID()
                }
            } else {
                try? runtimeStore.removePID()
            }
            try? runtimeStore.removeActiveConfigDigest()
            launchedProcess = nil
            throw error
        }
    }

    private func sanitize(_ message: String, secrets: [String]) -> String {
        secrets
            .filter { !$0.isEmpty }
            .reduce(message) { partial, secret in
                partial.replacingOccurrences(of: secret, with: "<redacted>")
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
