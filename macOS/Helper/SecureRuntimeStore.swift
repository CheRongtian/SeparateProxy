import Darwin
import Foundation

enum SecureRuntimeStoreError: LocalizedError {
    case invalidDirectory
    case invalidFile(String)
    case systemCall(String, Int32)
    case invalidPID

    var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            return "The SeparateProxy runtime directory is not a secure root-owned directory."
        case let .invalidFile(name):
            return "The runtime file \(name) has an unexpected type, owner, or permissions."
        case let .systemCall(operation, code):
            return "The runtime file operation \(operation) failed with errno \(code)."
        case .invalidPID:
            return "The recorded sing-box PID is invalid."
        }
    }
}

final class SecureRuntimeStore {
    let baseURL: URL
    lazy var runtimeURL = baseURL.appendingPathComponent("runtime", isDirectory: true)
    lazy var configURL = runtimeURL.appendingPathComponent("config.json", isDirectory: false)
    lazy var logURL = runtimeURL.appendingPathComponent("sing-box.log", isDirectory: false)
    lazy var pidURL = runtimeURL.appendingPathComponent("sing-box.pid", isDirectory: false)
    lazy var activeConfigDigestURL = runtimeURL.appendingPathComponent(
        "active-config.sha256",
        isDirectory: false
    )

    private let expectedOwner: uid_t

    init(
        baseURL: URL = URL(
            fileURLWithPath: "/Library/Application Support/SeparateProxy",
            isDirectory: true
        ),
        expectedOwner: uid_t = 0
    ) {
        self.baseURL = baseURL
        self.expectedOwner = expectedOwner
    }

    func prepare() throws {
        try ensureSecureDirectory(at: baseURL.path)
        try ensureSecureDirectory(at: runtimeURL.path)
    }

    func writeConfig(_ data: Data) throws {
        try writeAtomically(data, named: configURL.lastPathComponent)
    }

    func writePID(_ pid: pid_t) throws {
        guard pid > 1 else {
            throw SecureRuntimeStoreError.invalidPID
        }
        try writeAtomically(Data("\(pid)\n".utf8), named: pidURL.lastPathComponent)
    }

    func readPID() throws -> pid_t? {
        guard let data = try readFileIfPresent(named: pidURL.lastPathComponent) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8),
              let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else {
            throw SecureRuntimeStoreError.invalidPID
        }
        return pid
    }

    func writeActiveConfigDigest(_ digest: String) throws {
        guard Self.isValidSHA256Digest(digest) else {
            throw SecureRuntimeStoreError.invalidFile(activeConfigDigestURL.lastPathComponent)
        }
        try writeAtomically(Data(digest.utf8), named: activeConfigDigestURL.lastPathComponent)
    }

    func readActiveConfigDigest() throws -> String? {
        guard let data = try readFileIfPresent(
            named: activeConfigDigestURL.lastPathComponent
        ),
        data.count == 64,
        let digest = String(data: data, encoding: .utf8),
        Self.isValidSHA256Digest(digest) else {
            return nil
        }
        return digest
    }

    func openLogForReplacement() throws -> FileHandle {
        try prepare()
        let directoryFD = try openRuntimeDirectory()
        defer { Darwin.close(directoryFD) }
        let name = logURL.lastPathComponent
        try validateExistingFileIfPresent(named: name, directoryFD: directoryFD)

        let descriptor = openat(
            directoryFD,
            name,
            O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SecureRuntimeStoreError.systemCall("open log", errno)
        }

        do {
            try validateOpenedRegularFile(descriptor, name: name)
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw SecureRuntimeStoreError.systemCall("chmod log", errno)
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func removeConfig() throws {
        try removeFileIfPresent(named: configURL.lastPathComponent)
    }

    func removePID() throws {
        try removeFileIfPresent(named: pidURL.lastPathComponent)
    }

    func removeActiveConfigDigest() throws {
        try removeFileIfPresent(named: activeConfigDigestURL.lastPathComponent)
    }

    private static func isValidSHA256Digest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private func ensureSecureDirectory(at path: String) throws {
        var information = stat()
        if lstat(path, &information) != 0 {
            guard errno == ENOENT else {
                throw SecureRuntimeStoreError.systemCall("inspect directory", errno)
            }
            if mkdir(path, S_IRWXU) != 0, errno != EEXIST {
                throw SecureRuntimeStoreError.systemCall("create directory", errno)
            }
            guard lstat(path, &information) == 0 else {
                throw SecureRuntimeStoreError.systemCall("inspect created directory", errno)
            }
        }

        guard information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == expectedOwner,
              information.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw SecureRuntimeStoreError.invalidDirectory
        }
        guard chmod(path, S_IRWXU) == 0 else {
            throw SecureRuntimeStoreError.systemCall("chmod directory", errno)
        }
    }

    private func openRuntimeDirectory() throws -> Int32 {
        let descriptor = open(runtimeURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SecureRuntimeStoreError.systemCall("open runtime directory", errno)
        }
        return descriptor
    }

    private func writeAtomically(_ data: Data, named name: String) throws {
        try prepare()
        let directoryFD = try openRuntimeDirectory()
        defer { Darwin.close(directoryFD) }
        try validateExistingFileIfPresent(named: name, directoryFD: directoryFD)

        let temporaryName = ".\(name).\(getpid()).\(UUID().uuidString).tmp"
        let descriptor = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SecureRuntimeStoreError.systemCall("create temporary file", errno)
        }

        var shouldRemoveTemporaryFile = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                unlinkat(directoryFD, temporaryName, 0)
            }
        }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                guard written >= 0 else {
                    throw SecureRuntimeStoreError.systemCall("write temporary file", errno)
                }
                offset += written
            }
        }

        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw SecureRuntimeStoreError.systemCall("chmod temporary file", errno)
        }
        guard fsync(descriptor) == 0 else {
            throw SecureRuntimeStoreError.systemCall("sync temporary file", errno)
        }
        guard renameat(directoryFD, temporaryName, directoryFD, name) == 0 else {
            throw SecureRuntimeStoreError.systemCall("replace runtime file", errno)
        }
        shouldRemoveTemporaryFile = false
    }

    private func readFileIfPresent(named name: String) throws -> Data? {
        try prepare()
        let directoryFD = try openRuntimeDirectory()
        defer { Darwin.close(directoryFD) }

        var information = stat()
        if fstatat(directoryFD, name, &information, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else {
                throw SecureRuntimeStoreError.systemCall("inspect runtime file", errno)
            }
            return nil
        }
        try validateFileInformation(information, name: name)

        let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SecureRuntimeStoreError.systemCall("open runtime file", errno)
        }
        defer { Darwin.close(descriptor) }
        try validateOpenedRegularFile(descriptor, name: name)

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                throw SecureRuntimeStoreError.systemCall("read runtime file", errno)
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= 4_096 else {
                throw SecureRuntimeStoreError.invalidFile(name)
            }
        }
        return result
    }

    private func removeFileIfPresent(named name: String) throws {
        try prepare()
        let directoryFD = try openRuntimeDirectory()
        defer { Darwin.close(directoryFD) }

        var information = stat()
        if fstatat(directoryFD, name, &information, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else {
                throw SecureRuntimeStoreError.systemCall("inspect runtime file", errno)
            }
            return
        }
        try validateFileInformation(information, name: name)
        guard unlinkat(directoryFD, name, 0) == 0 else {
            throw SecureRuntimeStoreError.systemCall("remove runtime file", errno)
        }
    }

    private func validateExistingFileIfPresent(named name: String, directoryFD: Int32) throws {
        var information = stat()
        if fstatat(directoryFD, name, &information, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else {
                throw SecureRuntimeStoreError.systemCall("inspect runtime file", errno)
            }
            return
        }
        try validateFileInformation(information, name: name)
    }

    private func validateOpenedRegularFile(_ descriptor: Int32, name: String) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw SecureRuntimeStoreError.systemCall("inspect opened file", errno)
        }
        try validateFileInformation(information, name: name)
    }

    private func validateFileInformation(_ information: stat, name: String) throws {
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == expectedOwner,
              information.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw SecureRuntimeStoreError.invalidFile(name)
        }
    }
}
