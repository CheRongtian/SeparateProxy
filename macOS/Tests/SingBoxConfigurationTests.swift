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
    private let codexPath = "/Users/test/.vscode/extensions/openai.chatgpt-1.2.3-darwin-arm64/bin/macos-aarch64/codex"
    private let vsCodePluginHelperPath = "/Users/test/Desktop/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"

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
        XCTAssertNil(configuration.route.rules[0].network)
        XCTAssertNil(configuration.route.rules[0].destinationPort)
        XCTAssertEqual(configuration.route.rules[0].action, "reject")
        XCTAssertNil(configuration.route.rules[0].sniffer)
        XCTAssertNil(configuration.route.rules[0].overrideDestination)
        XCTAssertEqual(configuration.route.rules[0].method, "default")
        XCTAssertEqual(configuration.route.rules[0].noDrop, true)
        XCTAssertNil(configuration.route.rules[0].outbound)

        XCTAssertEqual(
            configuration.route.rules[1].processPathRegex,
            [#"^/Applications/Google Chrome\.app/"#]
        )
        XCTAssertNil(configuration.route.rules[1].ipVersion)
        XCTAssertNil(configuration.route.rules[1].network)
        XCTAssertNil(configuration.route.rules[1].destinationPort)
        XCTAssertEqual(configuration.route.rules[1].action, "route")
        XCTAssertNil(configuration.route.rules[1].sniffer)
        XCTAssertNil(configuration.route.rules[1].overrideDestination)
        XCTAssertEqual(configuration.route.rules[1].outbound, "outline")
        XCTAssertEqual(configuration.route.final, "direct")
    }

    func testCodexDisabledIsFieldForFieldEqualToChromeBaseline() throws {
        let baseline = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app"
        )
        let codexDisabled = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil
        )

        XCTAssertEqual(codexDisabled, baseline)
        XCTAssertEqual(try codexDisabled.encodedJSON(), try baseline.encodedJSON())
    }

    func testCodexEnabledOnlyAppendsSniffAndExactRouteAfterChromeRules() throws {
        let baseline = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app"
        )
        let combined = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath
        )

        XCTAssertEqual(Array(combined.route.rules.prefix(2)), baseline.route.rules)
        XCTAssertEqual(combined.route.rules.count, 6)
        assertCodexSniffRule(combined.route.rules[2], codexPath: codexPath)
        XCTAssertEqual(combined.route.rules[3].action, "route")
        XCTAssertEqual(combined.route.rules[3].outbound, "outline")
        XCTAssertEqual(combined.route.rules[3].processPathRegex, combined.route.rules[2].processPathRegex)
        XCTAssertNil(combined.route.rules[3].network)
        XCTAssertNil(combined.route.rules[3].destinationPort)
        XCTAssertNil(combined.route.rules[3].sniffer)
        XCTAssertNil(combined.route.rules[3].overrideDestination)
        XCTAssertNil(combined.route.rules[3].ipVersion)
        XCTAssertNil(combined.route.rules[3].method)
        XCTAssertNil(combined.route.rules[3].noDrop)
        XCTAssertNil(combined.route.rules[2].ipVersion)
        assertVSCodePluginHelperRules(
            sniffRule: combined.route.rules[4],
            routeRule: combined.route.rules[5],
            helperPath: vsCodePluginHelperPath
        )
        XCTAssertEqual(combined.route.final, "direct")
    }

    func testCodexOnlyConfigurationKeepsFinalDirect() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath
        )

        XCTAssertEqual(configuration.route.rules.count, 4)
        assertCodexSniffRule(
            configuration.route.rules[0],
            codexPath: codexPath
        )
        XCTAssertEqual(configuration.route.rules[1].action, "route")
        XCTAssertEqual(configuration.route.rules[1].outbound, "outline")
        XCTAssertNil(configuration.route.rules[1].overrideDestination)
        assertVSCodePluginHelperRules(
            sniffRule: configuration.route.rules[2],
            routeRule: configuration.route.rules[3],
            helperPath: vsCodePluginHelperPath
        )
        XCTAssertEqual(configuration.route.final, "direct")
    }

    func testCodexRegexEscapesSpecialCharactersAndMatchesOnlyCodex() throws {
        let codexPath = "/Users/test/Dev Tools/(Stable)/.vscode/extensions/openai.chatgpt-1.2.3-darwin-arm64/bin/macos-aarch64/codex"
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath
        )
        let pattern = try XCTUnwrap(
            configuration.route.rules.first?.processPathRegex.first
        )
        let expression = try NSRegularExpression(pattern: pattern)

        XCTAssertEqual(numberOfMatches(expression, in: codexPath), 1)
        XCTAssertEqual(numberOfMatches(expression, in: codexPath + "-code-mode-host"), 0)
        XCTAssertEqual(
            numberOfMatches(
                expression,
                in: "/Users/test/.vscode/extensions/openai.chatgpt-1.2.3-darwin-arm64/bin/macos-aarch64/rg"
            ),
            0
        )
        XCTAssertEqual(numberOfMatches(expression, in: "/bin/zsh"), 0)
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
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 2)
        XCTAssertFalse(rules.contains { $0["action"] as? String == "sniff" })
        XCTAssertFalse(rules.contains { $0["override_destination"] != nil })
    }

    func testCodexSniffJSONUsesPatchedSchemaAndKeepsRoutePlain() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: configuration.encodedJSON()) as? [String: Any]
        )
        let route = try XCTUnwrap(object["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])

        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(rules[0]["network"] as? String, "tcp")
        XCTAssertEqual(rules[0]["port"] as? Int, 443)
        XCTAssertEqual(rules[0]["action"] as? String, "sniff")
        XCTAssertEqual(rules[0]["sniffer"] as? [String], ["tls"])
        XCTAssertEqual(rules[0]["override_destination"] as? Bool, true)
        XCTAssertNil(rules[0]["outbound"])

        XCTAssertEqual(rules[1]["action"] as? String, "route")
        XCTAssertEqual(rules[1]["outbound"] as? String, "outline")
        XCTAssertNil(rules[1]["override_destination"])
        XCTAssertNil(rules[1]["network"])
        XCTAssertNil(rules[1]["port"])
        XCTAssertNil(rules[1]["sniffer"])
        XCTAssertNil(rules[1]["ip_version"])
        XCTAssertNil(rules[1]["dns"])

        XCTAssertEqual(rules[2]["network"] as? String, "tcp")
        XCTAssertEqual(rules[2]["port"] as? Int, 443)
        XCTAssertEqual(rules[2]["action"] as? String, "sniff")
        XCTAssertEqual(rules[2]["sniffer"] as? [String], ["tls"])
        XCTAssertNil(rules[2]["override_destination"])
        XCTAssertNil(rules[2]["override_address"])
        XCTAssertNil(rules[2]["outbound"])

        XCTAssertEqual(rules[3]["network"] as? String, "tcp")
        XCTAssertEqual(rules[3]["port"] as? Int, 443)
        XCTAssertEqual(rules[3]["protocol"] as? String, "tls")
        XCTAssertEqual(rules[3]["domain"] as? [String], ["chatgpt.com"])
        XCTAssertEqual(rules[3]["override_address"] as? String, "chatgpt.com")
        XCTAssertEqual(rules[3]["action"] as? String, "route")
        XCTAssertEqual(rules[3]["outbound"] as? String, "outline")
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

    func testSyntheticChromeAndCodexConfigurationPassesBundledSingBoxCheck() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath
        )
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-Codex-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try configuration.encodedJSON().write(to: temporaryURL, options: .atomic)

        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let singBoxURL = projectURL.appendingPathComponent("bin/sing-box")
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

    func testVSCodePluginHelperRegexMatchesOnlyExactPluginHelper() throws {
        let specialHelperPath = "/Users/test/Dev Tools/(Stable)/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: specialHelperPath
        )
        let pattern = try XCTUnwrap(configuration.route.rules[2].processPathRegex.first)
        let expression = try NSRegularExpression(pattern: pattern)

        XCTAssertEqual(numberOfMatches(expression, in: specialHelperPath), 1)
        XCTAssertEqual(
            numberOfMatches(
                expression,
                in: "/Users/test/Dev Tools/(Stable)/Visual Studio Code.app/Contents/MacOS/Code"
            ),
            0
        )
        XCTAssertEqual(
            numberOfMatches(
                expression,
                in: "/Users/test/Dev Tools/(Stable)/Visual Studio Code.app/Contents/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)"
            ),
            0
        )
        XCTAssertEqual(
            numberOfMatches(
                expression,
                in: "/Users/test/Dev Tools/(Stable)/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
            ),
            0
        )
    }

    func testSharedExtensionHostRouteUsesExactChatGPTDomainOnly() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath
        )
        let routeRule = configuration.route.rules[3]

        XCTAssertEqual(routeRule.domains, ["chatgpt.com"])
        XCTAssertFalse(routeRule.domains?.contains("ab.chatgpt.com") ?? true)
        XCTAssertFalse(routeRule.domains?.contains("example.org") ?? true)
        XCTAssertEqual(routeRule.protocolName, "tls")
        XCTAssertEqual(routeRule.overrideAddress, "chatgpt.com")
    }

    func testCodexConfigurationRequiresVSCodePluginHelperPath() {
        XCTAssertThrowsError(try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: nil
        )) { error in
            XCTAssertEqual(
                error as? SingBoxConfigurationError,
                .invalidVSCodePluginHelperExecutablePath
            )
        }
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

    private func numberOfMatches(
        _ expression: NSRegularExpression,
        in value: String
    ) -> Int {
        expression.numberOfMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
    }

    private func assertCodexSniffRule(
        _ rule: SingBoxConfiguration.Route.Rule,
        codexPath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let escapedPath = NSRegularExpression.escapedPattern(for: codexPath)
            .replacingOccurrences(of: #"\/"#, with: "/")
        XCTAssertEqual(rule.processPathRegex, ["^\(escapedPath)$"], file: file, line: line)
        XCTAssertNil(rule.ipVersion, file: file, line: line)
        XCTAssertEqual(rule.network, "tcp", file: file, line: line)
        XCTAssertEqual(rule.destinationPort, 443, file: file, line: line)
        XCTAssertEqual(rule.action, "sniff", file: file, line: line)
        XCTAssertEqual(rule.sniffer, ["tls"], file: file, line: line)
        XCTAssertEqual(rule.overrideDestination, true, file: file, line: line)
        XCTAssertNil(rule.protocolName, file: file, line: line)
        XCTAssertNil(rule.domains, file: file, line: line)
        XCTAssertNil(rule.overrideAddress, file: file, line: line)
        XCTAssertNil(rule.method, file: file, line: line)
        XCTAssertNil(rule.noDrop, file: file, line: line)
        XCTAssertNil(rule.outbound, file: file, line: line)
    }

    private func assertVSCodePluginHelperRules(
        sniffRule: SingBoxConfiguration.Route.Rule,
        routeRule: SingBoxConfiguration.Route.Rule,
        helperPath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let escapedPath = NSRegularExpression.escapedPattern(for: helperPath)
            .replacingOccurrences(of: #"\/"#, with: "/")
        let expectedRegex = ["^\(escapedPath)$"]

        XCTAssertEqual(sniffRule.processPathRegex, expectedRegex, file: file, line: line)
        XCTAssertEqual(sniffRule.network, "tcp", file: file, line: line)
        XCTAssertEqual(sniffRule.destinationPort, 443, file: file, line: line)
        XCTAssertEqual(sniffRule.action, "sniff", file: file, line: line)
        XCTAssertEqual(sniffRule.sniffer, ["tls"], file: file, line: line)
        XCTAssertNil(sniffRule.overrideDestination, file: file, line: line)
        XCTAssertNil(sniffRule.overrideAddress, file: file, line: line)
        XCTAssertNil(sniffRule.outbound, file: file, line: line)

        XCTAssertEqual(routeRule.processPathRegex, expectedRegex, file: file, line: line)
        XCTAssertEqual(routeRule.network, "tcp", file: file, line: line)
        XCTAssertEqual(routeRule.destinationPort, 443, file: file, line: line)
        XCTAssertEqual(routeRule.protocolName, "tls", file: file, line: line)
        XCTAssertEqual(routeRule.domains, ["chatgpt.com"], file: file, line: line)
        XCTAssertEqual(routeRule.action, "route", file: file, line: line)
        XCTAssertEqual(routeRule.outbound, "outline", file: file, line: line)
        XCTAssertEqual(routeRule.overrideAddress, "chatgpt.com", file: file, line: line)
        XCTAssertNil(routeRule.overrideDestination, file: file, line: line)
    }
}
