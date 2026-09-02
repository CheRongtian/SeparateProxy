import Darwin
import Foundation
import XCTest
@testable import SeparateProxyCore

final class DockerHubDiscoveryTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-DockerHub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testValidDockerApplicationDerivesFixedExecutables() throws {
        let application = try makeDockerApplication()
        let installation = try discovery(for: application).discoverActiveInstallation()

        XCTAssertEqual(installation.applicationBundlePath, application.path)
        XCTAssertEqual(
            installation.backendExecutablePath,
            application.appendingPathComponent(
                DockerHubDiscovery.backendExecutableRelativePath
            ).path
        )
        XCTAssertEqual(
            installation.cliExecutablePath,
            application.appendingPathComponent(
                DockerHubDiscovery.cliExecutableRelativePath
            ).path
        )
    }

    func testDisabledTargetDoesNotRunDiscovery() throws {
        var discoveryWasCalled = false
        let installation = try DockerHubDiscovery.resolveIfEnabled(false) {
            discoveryWasCalled = true
            throw DockerHubDiscoveryError.notInstalled
        }

        XCTAssertNil(installation)
        XCTAssertFalse(discoveryWasCalled)
    }

    func testInvalidBundleIdentifierIsRejected() throws {
        let application = try makeDockerApplication(
            bundleIdentifier: "example.invalid"
        )

        XCTAssertThrowsError(
            try discovery(for: application).discoverActiveInstallation()
        )
    }

    func testMissingBackendIsRejected() throws {
        let application = try makeDockerApplication()
        try FileManager.default.removeItem(
            at: application.appendingPathComponent(
                DockerHubDiscovery.backendExecutableRelativePath
            )
        )

        XCTAssertThrowsError(
            try discovery(for: application).discoverActiveInstallation()
        )
    }

    func testBackendSymlinkIsRejected() throws {
        let application = try makeDockerApplication()
        let backend = application.appendingPathComponent(
            DockerHubDiscovery.backendExecutableRelativePath
        )
        try FileManager.default.removeItem(at: backend)
        try FileManager.default.createSymbolicLink(
            at: backend,
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        XCTAssertThrowsError(
            try discovery(for: application).discoverActiveInstallation()
        )
    }

    func testNestedDirectoryEscapeIsRejected() throws {
        let application = try makeDockerApplication()
        let resources = application.appendingPathComponent("Contents/Resources")
        let binDirectory = resources.appendingPathComponent("bin")
        try FileManager.default.removeItem(at: binDirectory)

        let outsideBin = temporaryDirectory.appendingPathComponent("outside-bin")
        try FileManager.default.createDirectory(
            at: outsideBin,
            withIntermediateDirectories: true
        )
        try writeExecutable(at: outsideBin.appendingPathComponent("docker"))
        try FileManager.default.createSymbolicLink(
            at: binDirectory,
            withDestinationURL: outsideBin
        )

        XCTAssertThrowsError(
            try discovery(for: application).discoverActiveInstallation()
        )
    }

    func testMissingBundledCLIIsRejected() throws {
        let application = try makeDockerApplication()
        try FileManager.default.removeItem(
            at: application.appendingPathComponent(
                DockerHubDiscovery.cliExecutableRelativePath
            )
        )

        XCTAssertThrowsError(
            try discovery(for: application).discoverActiveInstallation()
        )
    }

    func testBundledCLISymlinkIsRejected() throws {
        let application = try makeDockerApplication()
        let cli = application.appendingPathComponent(
            DockerHubDiscovery.cliExecutableRelativePath
        )
        try FileManager.default.removeItem(at: cli)
        try FileManager.default.createSymbolicLink(
            at: cli,
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        XCTAssertThrowsError(
            try discovery(for: application).discoverActiveInstallation()
        )
    }

    private func discovery(for application: URL?) -> DockerHubDiscovery {
        DockerHubDiscovery {
            application
        }
    }

    private func makeDockerApplication(
        bundleIdentifier: String = DockerHubDiscovery.applicationBundleIdentifier
    ) throws -> URL {
        let application = temporaryDirectory.appendingPathComponent(
            "Docker.app",
            isDirectory: true
        )
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesBin = contents
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: macOS,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: resourcesBin,
            withIntermediateDirectories: true
        )

        let information: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Docker",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Docker Desktop",
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: information,
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try writeExecutable(at: macOS.appendingPathComponent("Docker Desktop"))
        try writeExecutable(
            at: application.appendingPathComponent(
                DockerHubDiscovery.backendExecutableRelativePath
            )
        )
        try writeExecutable(
            at: application.appendingPathComponent(
                DockerHubDiscovery.cliExecutableRelativePath
            )
        )
        return application.standardizedFileURL
    }

    private func writeExecutable(at url: URL) throws {
        try Data("test executable".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
