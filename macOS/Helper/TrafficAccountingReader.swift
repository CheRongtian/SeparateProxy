import Darwin
import Foundation
import SeparateProxyCore

enum TrafficAccountingReaderError: LocalizedError, Equatable {
    case unavailable
    case invalidRuntimeDirectory
    case invalidSocket
    case timeout
    case responseTooLarge
    case malformedSnapshot
    case unsupportedVersion(Int)
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Traffic accounting is unavailable."
        case .invalidRuntimeDirectory:
            return "The traffic accounting runtime directory is invalid."
        case .invalidSocket:
            return "The traffic accounting socket is invalid."
        case .timeout:
            return "The traffic accounting query timed out."
        case .responseTooLarge:
            return "The traffic accounting response exceeded the size limit."
        case .malformedSnapshot:
            return "The traffic accounting response was malformed."
        case let .unsupportedVersion(version):
            return "Traffic accounting snapshot version \(version) is unsupported."
        case let .systemCall(operation, code):
            return "The traffic accounting operation \(operation) failed with errno \(code)."
        }
    }
}

enum TrafficAccountingReplyBuilder {
    static func success(_ snapshot: TrafficCountersSnapshot) -> NSDictionary {
        [
            TrafficAccountingReplyKey.success: true,
            TrafficAccountingReplyKey.message: "Traffic counters are available.",
            TrafficAccountingReplyKey.sessionIdentifier: snapshot.sessionIdentifier,
            TrafficAccountingReplyKey.proxyUploadBytes: NSNumber(value: snapshot.proxyUploadBytes),
            TrafficAccountingReplyKey.proxyDownloadBytes: NSNumber(value: snapshot.proxyDownloadBytes),
            TrafficAccountingReplyKey.directUploadBytes: NSNumber(value: snapshot.directUploadBytes),
            TrafficAccountingReplyKey.directDownloadBytes: NSNumber(value: snapshot.directDownloadBytes),
        ]
    }

    static func failure(_ error: Error) -> NSDictionary {
        [
            TrafficAccountingReplyKey.success: false,
            TrafficAccountingReplyKey.message: error.localizedDescription,
        ]
    }
}

final class TrafficAccountingReader {
    static let maximumResponseBytes = 4_096
    static let timeoutMilliseconds: Int32 = 1_000

    private let socketURL: URL
    private let expectedOwner: uid_t
    private let snapshotProvider: (() throws -> Data)?

    init() {
        socketURL = URL(fileURLWithPath: TrafficAccountingConstants.socketPath)
        expectedOwner = 0
        snapshotProvider = nil
    }

    init(
        socketURL: URL,
        expectedOwner: uid_t,
        snapshotProvider: (() throws -> Data)? = nil
    ) {
        self.socketURL = socketURL
        self.expectedOwner = expectedOwner
        self.snapshotProvider = snapshotProvider
    }

    func readSnapshot() throws -> TrafficCountersSnapshot {
        let data = try snapshotProvider?() ?? readSocketSnapshot()
        guard data.count <= Self.maximumResponseBytes else {
            throw TrafficAccountingReaderError.responseTooLarge
        }
        let snapshot: TrafficCountersSnapshot
        do {
            snapshot = try JSONDecoder().decode(TrafficCountersSnapshot.self, from: data)
        } catch {
            throw TrafficAccountingReaderError.malformedSnapshot
        }
        guard snapshot.version == TrafficAccountingConstants.snapshotVersion else {
            throw TrafficAccountingReaderError.unsupportedVersion(snapshot.version)
        }
        guard !snapshot.sessionIdentifier.isEmpty else {
            throw TrafficAccountingReaderError.malformedSnapshot
        }
        return snapshot
    }

    private func readSocketSnapshot() throws -> Data {
        try validateSocket()
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TrafficAccountingReaderError.systemCall("create socket", errno)
        }
        defer { Darwin.close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TrafficAccountingReaderError.systemCall("configure socket", errno)
        }
        try connect(descriptor)
        return try readBoundedResponse(descriptor)
    }

    private func validateSocket() throws {
        let runtimeURL = socketURL.deletingLastPathComponent().standardizedFileURL
        guard runtimeURL.path == runtimeURL.resolvingSymlinksInPath().path else {
            throw TrafficAccountingReaderError.invalidRuntimeDirectory
        }

        var directoryInformation = stat()
        guard lstat(runtimeURL.path, &directoryInformation) == 0 else {
            if errno == ENOENT {
                throw TrafficAccountingReaderError.unavailable
            }
            throw TrafficAccountingReaderError.systemCall("inspect runtime directory", errno)
        }
        guard directoryInformation.st_mode & S_IFMT == S_IFDIR,
              directoryInformation.st_uid == expectedOwner,
              directoryInformation.st_mode & 0o777 == 0o700 else {
            throw TrafficAccountingReaderError.invalidRuntimeDirectory
        }

        var socketInformation = stat()
        guard lstat(socketURL.path, &socketInformation) == 0 else {
            if errno == ENOENT {
                throw TrafficAccountingReaderError.unavailable
            }
            throw TrafficAccountingReaderError.systemCall("inspect traffic socket", errno)
        }
        guard socketInformation.st_mode & S_IFMT == S_IFSOCK,
              socketInformation.st_uid == expectedOwner,
              socketInformation.st_mode & 0o777 == 0o600 else {
            throw TrafficAccountingReaderError.invalidSocket
        }
    }

    private func connect(_ descriptor: Int32) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count <= capacity else {
            throw TrafficAccountingReaderError.invalidSocket
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                path.withUnsafeBufferPointer { source in
                    destination.initialize(from: source.baseAddress!, count: path.count)
                }
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result == 0 {
            return
        }
        guard errno == EINPROGRESS else {
            if errno == ENOENT || errno == ECONNREFUSED {
                throw TrafficAccountingReaderError.unavailable
            }
            throw TrafficAccountingReaderError.systemCall("connect", errno)
        }
        try waitForEvent(descriptor, events: Int16(POLLOUT))
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &length
        ) == 0 else {
            throw TrafficAccountingReaderError.systemCall("inspect connection", errno)
        }
        guard socketError == 0 else {
            if socketError == ENOENT || socketError == ECONNREFUSED {
                throw TrafficAccountingReaderError.unavailable
            }
            throw TrafficAccountingReaderError.systemCall("connect", socketError)
        }
    }

    private func readBoundedResponse(_ descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while result.count <= Self.maximumResponseBytes {
            try waitForEvent(descriptor, events: Int16(POLLIN))
            let remaining = Self.maximumResponseBytes + 1 - result.count
            let readCount = Darwin.read(
                descriptor,
                &buffer,
                min(buffer.count, remaining)
            )
            if readCount == 0 {
                return result
            }
            if readCount < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                throw TrafficAccountingReaderError.systemCall("read", errno)
            }
            result.append(buffer, count: readCount)
            if result.count > Self.maximumResponseBytes {
                throw TrafficAccountingReaderError.responseTooLarge
            }
        }
        throw TrafficAccountingReaderError.responseTooLarge
    }

    private func waitForEvent(_ descriptor: Int32, events: Int16) throws {
        var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
        let result = Darwin.poll(&pollDescriptor, 1, Self.timeoutMilliseconds)
        if result == 0 {
            throw TrafficAccountingReaderError.timeout
        }
        guard result > 0 else {
            throw TrafficAccountingReaderError.systemCall("poll", errno)
        }
        if pollDescriptor.revents & Int16(POLLNVAL | POLLERR) != 0 {
            throw TrafficAccountingReaderError.unavailable
        }
    }
}
