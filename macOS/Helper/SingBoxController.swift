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

final class SingBoxController {
    private let runtimeStore: SecureRuntimeStore
    private let singBoxURL: URL
    private var launchedProcess: Process?

    init(runtimeStore: SecureRuntimeStore) throws {
        self.runtimeStore = runtimeStore
        let helperURL = try Self.currentExecutableURL()
        singBoxURL = helperURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("sing-box", isDirectory: false)

        guard FileManager.default.isExecutableFile(atPath: singBoxURL.path) else {
            throw SingBoxControllerError.bundledBinaryMissing
        }
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

    func state() throws -> ProxyState {
        if let process = launchedProcess, process.isRunning {
            return .running
        }
        guard let pid = try runtimeStore.readPID() else {
            return .stopped
        }
        return try matchesExpectedProcess(pid: pid) ? .running : .stopped
    }

    func checkConfiguration(redacting secrets: [String]) throws {
        let result = try runAndCapture(
            executableURL: singBoxURL,
            arguments: ["check", "-c", runtimeStore.configURL.path]
        )
        guard result.status == 0 else {
            let sanitized = sanitize(result.output, secrets: secrets)
            throw SingBoxControllerError.configurationCheckFailed(
                sanitized.isEmpty ? "unknown validation error" : sanitized
            )
        }
    }

    func start() throws -> pid_t {
        if let pid = try runtimeStore.readPID(), try matchesExpectedProcess(pid: pid) {
            return pid
        }
        try? runtimeStore.removePID()

        let logHandle = try runtimeStore.openLogForReplacement()
        let process = Process()
        process.executableURL = singBoxURL
        process.arguments = ["run", "-c", runtimeStore.configURL.path]
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
            guard process.isRunning else {
                throw SingBoxControllerError.launchFailed("the process exited immediately")
            }
            try runtimeStore.writePID(process.processIdentifier)
            launchedProcess = process
            return process.processIdentifier
        } catch {
            if process.isRunning {
                process.terminate()
            }
            try? runtimeStore.removePID()
            throw error
        }
    }

    func stop() throws {
        guard let pid = try runtimeStore.readPID() else {
            try runtimeStore.removeConfig()
            return
        }
        guard try matchesExpectedProcess(pid: pid) else {
            throw SingBoxControllerError.recordedProcessMismatch
        }
        guard Darwin.kill(pid, SIGTERM) == 0 else {
            if errno == ESRCH {
                try runtimeStore.removePID()
                try runtimeStore.removeConfig()
                launchedProcess = nil
                return
            }
            throw SecureRuntimeStoreError.systemCall("terminate sing-box", errno)
        }

        for _ in 0..<50 {
            if try !matchesExpectedProcess(pid: pid) {
                try runtimeStore.removePID()
                try runtimeStore.removeConfig()
                launchedProcess = nil
                return
            }
            usleep(100_000)
        }
        throw SingBoxControllerError.stopTimedOut
    }

    private var expectedCommand: String {
        "\(singBoxURL.path) run -c \(runtimeStore.configURL.path)"
    }

    private func matchesExpectedProcess(pid: pid_t) throws -> Bool {
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
            && commandResult.output.trimmingCharacters(in: .whitespacesAndNewlines) == expectedCommand
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

    private func sanitize(_ message: String, secrets: [String]) -> String {
        secrets
            .filter { !$0.isEmpty }
            .reduce(message) { partial, secret in
                partial.replacingOccurrences(of: secret, with: "<redacted>")
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
