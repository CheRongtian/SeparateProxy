import Foundation
import XCTest
@testable import SeparateProxyCore

final class SingBoxConfigurationTests: XCTestCase {
    private let outline = OutlineAccessKey(
        server: "192.0.2.1",
        serverPort: 8388,
        method: "aes-256-gcm",
        password: "test-only-password"
    )

    func testBuildsValidatedChromeOnlyRules() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app"
        )

        XCTAssertEqual(configuration.inbounds.count, 1)
        XCTAssertEqual(configuration.inbounds[0].address, [
            "172.19.0.1/30",
            "fdfe:dcba:9876::1/126",
        ])
        XCTAssertTrue(configuration.inbounds[0].autoRoute)
        XCTAssertEqual(configuration.inbounds[0].stack, "system")

        XCTAssertEqual(configuration.route.rules.count, 2)
        XCTAssertEqual(
            configuration.route.rules[0].processPathRegex,
            [#"^/Applications/Google Chrome\.app/"#]
        )
        XCTAssertEqual(configuration.route.rules[0].ipVersion, 6)
        XCTAssertEqual(configuration.route.rules[0].action, "reject")
        XCTAssertEqual(configuration.route.rules[0].method, "default")
        XCTAssertEqual(configuration.route.rules[0].noDrop, true)
        XCTAssertNil(configuration.route.rules[0].outbound)

        XCTAssertEqual(
            configuration.route.rules[1].processPathRegex,
            [#"^/Applications/Google Chrome\.app/"#]
        )
        XCTAssertNil(configuration.route.rules[1].ipVersion)
        XCTAssertEqual(configuration.route.rules[1].action, "route")
        XCTAssertEqual(configuration.route.rules[1].outbound, "outline")
        XCTAssertEqual(configuration.route.final, "direct")
    }

    func testEncodesSyntheticConfigurationWithoutNetworkAccess() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app"
        )
        let data = try configuration.encodedJSON()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let route = try XCTUnwrap(object["route"] as? [String: Any])

        XCTAssertEqual(route["final"] as? String, "direct")
        XCTAssertNotNil(route["rules"] as? [[String: Any]])
    }

    func testSyntheticConfigurationPassesBundledSingBoxCheck() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app"
        )
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try configuration.encodedJSON().write(to: temporaryURL, options: .atomic)

        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let singBoxURL = projectURL.appendingPathComponent("bin/sing-box")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: singBoxURL.path))

        let process = Process()
        let output = Pipe()
        process.executableURL = singBoxURL
        process.arguments = ["check", "-c", temporaryURL.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let message = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, message)
    }

    func testCodeSigningRequirementRejectsInvalidComponents() {
        XCTAssertNil(CodeSigningRequirementBuilder.requirement(
            identifier: "com.example.Bad Identifier",
            teamIdentifier: "ABCDEFGHIJ"
        ))
        XCTAssertNil(CodeSigningRequirementBuilder.requirement(
            identifier: "com.example.SeparateProxy",
            teamIdentifier: ""
        ))
    }

    func testCodeSigningRequirementUsesExactIdentifierAndTeam() throws {
        let requirement = try XCTUnwrap(CodeSigningRequirementBuilder.requirement(
            identifier: "com.example.SeparateProxy",
            teamIdentifier: "ABCDEFGHIJ"
        ))
        XCTAssertTrue(requirement.contains("identifier \"com.example.SeparateProxy\""))
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"ABCDEFGHIJ\""))
    }

    func testDerivesMatchingAppAndHelperBundleIdentifiers() throws {
        let appIdentifier = "com.example.SeparateProxy"
        let helperIdentifier = SeparateProxyIdentifiers.helperBundleIdentifier(
            forAppIdentifier: appIdentifier
        )

        XCTAssertEqual(helperIdentifier, "com.example.SeparateProxy.Helper")
        XCTAssertEqual(
            SeparateProxyIdentifiers.appBundleIdentifier(
                forHelperIdentifier: helperIdentifier
            ),
            appIdentifier
        )
        XCTAssertNil(SeparateProxyIdentifiers.appBundleIdentifier(
            forHelperIdentifier: "com.example.Unrelated"
        ))
    }
}
