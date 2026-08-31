import Darwin
import Foundation
import XCTest
@testable import SeparateProxyCore

final class AppleGitDiscoveryTests: XCTestCase {
    func testDiscoversValidatedAppleGitLayout() throws {
        let fixture = try AppleGitFixture()
        defer { fixture.remove() }

        let installation = try fixture.discovery().discoverActiveInstallation()

        XCTAssertEqual(installation.developerDirectoryPath, fixture.developerDirectory.path)
        XCTAssertEqual(installation.gitExecutablePath, fixture.gitExecutable.path)
        XCTAssertEqual(installation.httpsHelperEntryPath, fixture.httpsHelper.path)
        XCTAssertEqual(installation.canonicalHTTPHelperPath, fixture.httpHelper.path)
    }

    func testDerivesExpectedPathsFromActiveDeveloperDirectory() throws {
        let fixture = try AppleGitFixture()
        defer { fixture.remove() }

        let installation = try fixture.discovery().discoverActiveInstallation()

        XCTAssertTrue(installation.gitExecutablePath.hasSuffix("/usr/bin/git"))
        XCTAssertTrue(
            installation.httpsHelperEntryPath.hasSuffix(
                "/usr/libexec/git-core/git-remote-https"
            )
        )
        XCTAssertTrue(
            installation.canonicalHTTPHelperPath.hasSuffix(
                "/usr/libexec/git-core/git-remote-http"
            )
        )
    }

    func testRejectsUnexpectedHTTPSHelperTarget() throws {
        let fixture = try AppleGitFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.httpsHelper)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.httpsHelper.path,
            withDestinationPath: "unexpected-helper"
        )

        XCTAssertThrowsError(try fixture.discovery().discoverActiveInstallation()) { error in
            guard case .invalidInstallation = error as? AppleGitDiscoveryError else {
                return XCTFail("Expected invalidInstallation, received \(error)")
            }
        }
    }

    func testRejectsCanonicalHelperPathEscape() throws {
        let fixture = try AppleGitFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside-helper")
        try fixture.writeExecutable(at: outside)
        try FileManager.default.removeItem(at: fixture.httpHelper)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.httpHelper.path,
            withDestinationPath: outside.path
        )

        XCTAssertThrowsError(try fixture.discovery().discoverActiveInstallation()) { error in
            guard case .invalidInstallation = error as? AppleGitDiscoveryError else {
                return XCTFail("Expected invalidInstallation, received \(error)")
            }
        }
    }

    func testRejectsMissingGitExecutable() throws {
        let fixture = try AppleGitFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.gitExecutable)

        XCTAssertThrowsError(try fixture.discovery().discoverActiveInstallation()) { error in
            XCTAssertEqual(error as? AppleGitDiscoveryError, .notInstalled)
        }
    }

    func testRejectsMissingHTTPSHelper() throws {
        let fixture = try AppleGitFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.httpsHelper)

        XCTAssertThrowsError(try fixture.discovery().discoverActiveInstallation()) { error in
            XCTAssertEqual(error as? AppleGitDiscoveryError, .notInstalled)
        }
    }

    func testRejectsNonExecutableCanonicalHelper() throws {
        let fixture = try AppleGitFixture()
        defer { fixture.remove() }
        guard chmod(fixture.httpHelper.path, S_IRUSR | S_IWUSR) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        XCTAssertThrowsError(try fixture.discovery().discoverActiveInstallation()) { error in
            guard case .invalidInstallation = error as? AppleGitDiscoveryError else {
                return XCTFail("Expected invalidInstallation, received \(error)")
            }
        }
    }

    func testDisabledTargetDoesNotRunDiscovery() throws {
        var discoveryRan = false
        let installation = try AppleGitDiscovery.resolveIfEnabled(false) {
            discoveryRan = true
            throw AppleGitDiscoveryError.notInstalled
        }

        XCTAssertNil(installation)
        XCTAssertFalse(discoveryRan)
    }
}

private final class AppleGitFixture {
    let root: URL
    let developerDirectory: URL
    let gitExecutable: URL
    let httpsHelper: URL
    let httpHelper: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SeparateProxy-AppleGit-\(UUID().uuidString)",
            isDirectory: true
        )
        developerDirectory = root.appendingPathComponent(
            "Developer Tools (Synthetic).app/Contents/Developer",
            isDirectory: true
        )
        gitExecutable = developerDirectory.appendingPathComponent(
            AppleGitDiscovery.gitExecutableRelativePath
        )
        httpsHelper = developerDirectory.appendingPathComponent(
            AppleGitDiscovery.httpsHelperRelativePath
        )
        httpHelper = developerDirectory.appendingPathComponent(
            AppleGitDiscovery.httpHelperRelativePath
        )

        try FileManager.default.createDirectory(
            at: gitExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: httpHelper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeExecutable(at: gitExecutable)
        try writeExecutable(at: httpHelper)
        try FileManager.default.createSymbolicLink(
            atPath: httpsHelper.path,
            withDestinationPath: httpHelper.lastPathComponent
        )
    }

    func discovery() -> AppleGitDiscovery {
        AppleGitDiscovery(
            expectedOwner: getuid(),
            activeDeveloperDirectory: { self.developerDirectory.path }
        )
    }

    func writeExecutable(at url: URL) throws {
        try Data("synthetic executable".utf8).write(to: url)
        guard chmod(url.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
