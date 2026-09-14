import Darwin
import Foundation
import XCTest
@testable import SeparateProxyCore

final class HomebrewDiscoveryTests: XCTestCase {
    func testDefaultPrefixesMatchSupportedArchitectures() {
        XCTAssertEqual(
            HomebrewDiscovery.defaultPrefixPath(for: .appleSilicon),
            "/opt/homebrew"
        )
        XCTAssertEqual(
            HomebrewDiscovery.defaultPrefixPath(for: .intel),
            "/usr/local"
        )
    }

    func testDiscoversValidDefaultPrefixStructure() throws {
        let fixture = try HomebrewFixture()
        defer { fixture.remove() }

        let installation = try fixture.discovery().discoverDefaultInstallation()

        XCTAssertEqual(installation.prefixPath, fixture.prefix.path)
        XCTAssertEqual(installation.brewExecutablePath, fixture.brewExecutable.path)
        XCTAssertEqual(installation.libraryPath, fixture.library.path)
    }

    func testMissingBrewIsNotInstalled() throws {
        let fixture = try HomebrewFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.brewExecutable)

        XCTAssertThrowsError(try fixture.discovery().discoverDefaultInstallation()) { error in
            XCTAssertEqual(error as? HomebrewDiscoveryError, .notInstalled)
        }
    }

    func testMissingLibraryIsNotInstalled() throws {
        let fixture = try HomebrewFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.library)

        XCTAssertThrowsError(try fixture.discovery().discoverDefaultInstallation()) { error in
            XCTAssertEqual(error as? HomebrewDiscoveryError, .notInstalled)
        }
    }

    func testRejectsInvalidBrewPathStructure() throws {
        let fixture = try HomebrewFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.brewExecutable)
        try FileManager.default.createDirectory(
            at: fixture.brewExecutable,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try fixture.discovery().discoverDefaultInstallation()) { error in
            guard case .invalidInstallation = error as? HomebrewDiscoveryError else {
                return XCTFail("Expected invalidInstallation, received \(error)")
            }
        }
    }

    func testRejectsInvalidLibraryPathStructure() throws {
        let fixture = try HomebrewFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.library)
        try Data("not a directory".utf8).write(to: fixture.library)

        XCTAssertThrowsError(try fixture.discovery().discoverDefaultInstallation()) { error in
            guard case .invalidInstallation = error as? HomebrewDiscoveryError else {
                return XCTFail("Expected invalidInstallation, received \(error)")
            }
        }
    }

    func testDisabledTargetDoesNotRunDiscovery() throws {
        var discoveryRan = false
        let installation = try HomebrewDiscovery.resolveIfEnabled(false) {
            discoveryRan = true
            throw HomebrewDiscoveryError.notInstalled
        }

        XCTAssertNil(installation)
        XCTAssertFalse(discoveryRan)
    }
}

private final class HomebrewFixture {
    let root: URL
    let prefix: URL
    let brewExecutable: URL
    let library: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SeparateProxy-Homebrew-\(UUID().uuidString)",
            isDirectory: true
        )
        prefix = root.appendingPathComponent("homebrew", isDirectory: true)
        brewExecutable = prefix.appendingPathComponent("bin/brew")
        library = prefix.appendingPathComponent("Library/Homebrew", isDirectory: true)

        try FileManager.default.createDirectory(
            at: brewExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: library,
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: brewExecutable)
        guard chmod(brewExecutable.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func discovery() -> HomebrewDiscovery {
        HomebrewDiscovery(prefixURL: prefix)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
