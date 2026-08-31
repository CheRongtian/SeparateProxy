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
    private let gitInstallation = AppleGitInstallation(
        developerDirectoryPath: "/Applications/Developer Tools (Stable).app/Contents/Developer",
        gitExecutablePath: "/Applications/Developer Tools (Stable).app/Contents/Developer/usr/bin/git",
        httpsHelperEntryPath: "/Applications/Developer Tools (Stable).app/Contents/Developer/usr/libexec/git-core/git-remote-https",
        canonicalHTTPHelperPath: "/Applications/Developer Tools (Stable).app/Contents/Developer/usr/libexec/git-core/git-remote-http"
    )

    func testEmptyProxyWebsiteListGeneratesOnlyChromeIPv6CompatibilityRule() throws {
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

        XCTAssertEqual(configuration.route.rules.count, 1)
        assertChromeIPv6CompatibilityRule(configuration.route.rules[0])
        XCTAssertEqual(configuration.route.final, "direct")
        XCTAssertTrue(configuration.experimental.trafficAccounting.enabled)
        XCTAssertEqual(
            configuration.experimental.trafficAccounting.socketPath,
            TrafficAccountingConstants.socketPath
        )
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
        let codexDisabledJSON = try JSONSerialization.jsonObject(
            with: codexDisabled.encodedJSON()
        ) as? NSDictionary
        let baselineJSON = try JSONSerialization.jsonObject(
            with: baseline.encodedJSON()
        ) as? NSDictionary
        XCTAssertEqual(codexDisabledJSON, baselineJSON)
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

        XCTAssertEqual(Array(combined.route.rules.prefix(baseline.route.rules.count)), baseline.route.rules)
        XCTAssertEqual(combined.route.rules.count, baseline.route.rules.count + 4)
        let codexStart = baseline.route.rules.count
        assertCodexSniffRule(combined.route.rules[codexStart], codexPath: codexPath)
        XCTAssertEqual(combined.route.rules[codexStart + 1].action, "route")
        XCTAssertEqual(combined.route.rules[codexStart + 1].outbound, "outline")
        XCTAssertEqual(
            combined.route.rules[codexStart + 1].processPathRegex,
            combined.route.rules[codexStart].processPathRegex
        )
        XCTAssertNil(combined.route.rules[codexStart + 1].network)
        XCTAssertNil(combined.route.rules[codexStart + 1].destinationPort)
        XCTAssertNil(combined.route.rules[codexStart + 1].sniffer)
        XCTAssertNil(combined.route.rules[codexStart + 1].overrideDestination)
        XCTAssertNil(combined.route.rules[codexStart + 1].ipVersion)
        XCTAssertNil(combined.route.rules[codexStart + 1].method)
        XCTAssertNil(combined.route.rules[codexStart + 1].noDrop)
        XCTAssertNil(combined.route.rules[codexStart].ipVersion)
        assertVSCodePluginHelperRules(
            sniffRule: combined.route.rules[codexStart + 2],
            routeRule: combined.route.rules[codexStart + 3],
            helperPath: vsCodePluginHelperPath
        )
        XCTAssertEqual(combined.route.final, "direct")
    }

    func testGitDisabledIsFieldForFieldEqualToChromeAndCodexBaseline() throws {
        let baseline = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath
        )
        let gitDisabled = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: nil
        )

        XCTAssertEqual(gitDisabled, baseline)
        XCTAssertEqual(try gitDisabled.encodedJSON(), try baseline.encodedJSON())
    }

    func testGitEnabledOnlyAppendsTwoRulesAfterExistingChromeAndCodexRules() throws {
        let baseline = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath
        )
        let combined = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation
        )

        XCTAssertEqual(
            Array(combined.route.rules.prefix(baseline.route.rules.count)),
            baseline.route.rules
        )
        XCTAssertEqual(combined.route.rules.count, baseline.route.rules.count + 2)
        assertGitRules(
            sniffRule: combined.route.rules[baseline.route.rules.count],
            routeRule: combined.route.rules[baseline.route.rules.count + 1]
        )
        XCTAssertEqual(combined.route.final, "direct")
        XCTAssertEqual(combined.experimental, baseline.experimental)
    }

    func testGitOnlyConfigurationUsesExactHTTPS443Boundary() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            gitInstallation: gitInstallation
        )

        XCTAssertEqual(configuration.route.rules.count, 2)
        assertGitRules(
            sniffRule: configuration.route.rules[0],
            routeRule: configuration.route.rules[1]
        )
        XCTAssertEqual(configuration.route.final, "direct")
    }

    func testGitRegexDoesNotMatchExcludedExecutables() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            gitInstallation: gitInstallation
        )
        let expressions = try configuration.route.rules[0].processPathRegex.map {
            try NSRegularExpression(pattern: $0)
        }

        for excludedPath in [
            "/usr/bin/ssh",
            "/opt/homebrew/bin/git-lfs",
            "/opt/homebrew/bin/gh",
            "/usr/bin/git",
            "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
        ] {
            XCTAssertTrue(expressions.allSatisfy {
                numberOfMatches($0, in: excludedPath) == 0
            })
        }
    }

    func testInvalidGitHelperPairIsRejected() {
        let invalid = AppleGitInstallation(
            developerDirectoryPath: gitInstallation.developerDirectoryPath,
            gitExecutablePath: gitInstallation.gitExecutablePath,
            httpsHelperEntryPath: gitInstallation.httpsHelperEntryPath,
            canonicalHTTPHelperPath: "/tmp/git-remote-http"
        )

        XCTAssertThrowsError(try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            gitInstallation: invalid
        )) { error in
            XCTAssertEqual(error as? SingBoxConfigurationError, .invalidGitHelperPaths)
        }
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
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0]["process_path_regex"] as? [String], [#"^/Applications/Google Chrome\.app/"#])
        XCTAssertEqual(rules[0]["ip_version"] as? Int, 6)
        XCTAssertEqual(rules[0]["action"] as? String, "reject")
        XCTAssertEqual(rules[0]["method"] as? String, "default")
        XCTAssertEqual(rules[0]["no_drop"] as? Bool, true)
        XCTAssertNil(rules[0]["domain"])
        XCTAssertNil(rules[0]["port"])
        XCTAssertNil(rules[0]["network"])
        XCTAssertNil(rules[0]["outbound"])
        XCTAssertFalse(rules.contains { $0["action"] as? String == "sniff" })
        XCTAssertFalse(rules.contains { $0["override_destination"] != nil })
        let experimental = try XCTUnwrap(object["experimental"] as? [String: Any])
        let trafficAccounting = try XCTUnwrap(
            experimental["traffic_accounting"] as? [String: Any]
        )
        XCTAssertEqual(trafficAccounting["enabled"] as? Bool, true)
        XCTAssertEqual(
            trafficAccounting["socket_path"] as? String,
            TrafficAccountingConstants.socketPath
        )
        XCTAssertEqual(Set(trafficAccounting.keys), ["enabled", "socket_path"])
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

    func testSyntheticChromeCodexAndGitConfigurationPassesBundledSingBoxCheck() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation
        )
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-Git-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try configuration.encodedJSON().write(to: temporaryURL, options: .atomic)

        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        let output = Pipe()
        process.executableURL = projectURL.appendingPathComponent("bin/sing-box")
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

    func testProxyWebsiteRulesAreExactOrderedAndLeaveChromeDefaultDirect() throws {
        let hostnames = ["chatgpt.com", "example.com"]
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            proxyWebsiteHostnames: hostnames
        )

        XCTAssertEqual(configuration.route.rules.count, 8)
        assertChromeIPv6CompatibilityRule(configuration.route.rules[0])
        assertChromeSniffRule(
            configuration.route.rules[1],
            network: "tcp",
            port: 443,
            sniffer: "tls"
        )
        assertChromeSniffRule(
            configuration.route.rules[2],
            network: "udp",
            port: 443,
            sniffer: "quic"
        )
        assertChromeSniffRule(
            configuration.route.rules[3],
            network: "tcp",
            port: 80,
            sniffer: "http"
        )
        assertChromeDomainRouteRule(
            configuration.route.rules[4],
            domains: ["chatgpt.com"],
            port: 80
        )
        assertChromeDomainRouteRule(
            configuration.route.rules[5],
            domains: ["chatgpt.com"],
            port: 443
        )
        assertChromeDomainRouteRule(
            configuration.route.rules[6],
            domains: ["example.com"],
            port: 80
        )
        assertChromeDomainRouteRule(
            configuration.route.rules[7],
            domains: ["example.com"],
            port: 443
        )
        XCTAssertEqual(configuration.route.final, "direct")
        XCTAssertFalse(configuration.route.rules.contains { rule in
            rule.action == "route" && rule.domains == nil
        })
        XCTAssertEqual(
            configuration.route.rules.filter { $0.action == "reject" }.count,
            1
        )
        XCTAssertFalse(configuration.route.rules.contains { rule in
            rule.action == "reject" && rule.domains != nil
        })
        XCTAssertFalse(
            configuration.route.rules
                .flatMap { $0.domains ?? [] }
                .contains("ab.chatgpt.com")
        )
        XCTAssertFalse(
            configuration.route.rules
                .flatMap { $0.domains ?? [] }
                .contains("evilchatgpt.com")
        )
        XCTAssertFalse(
            configuration.route.rules
                .flatMap { $0.domains ?? [] }
                .contains(ChromeInfrastructure.secureDNSHostname)
        )
        XCTAssertTrue(
            configuration.route.rules
                .filter { $0.action == "route" && $0.destinationPort == 443 }
                .allSatisfy { $0.network == nil }
        )
        XCTAssertEqual(configuration.route.rules.first?.action, "reject")
    }

    func testChromeAndCodexOnlyAppendUnchangedCodexRulesAfterWebsiteRules() throws {
        let chromeOnly = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            proxyWebsiteHostnames: ["chatgpt.com"]
        )
        let combined = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            proxyWebsiteHostnames: ["chatgpt.com"]
        )

        XCTAssertEqual(
            Array(combined.route.rules.prefix(chromeOnly.route.rules.count)),
            chromeOnly.route.rules
        )
        XCTAssertEqual(combined.route.rules.count, chromeOnly.route.rules.count + 4)
        XCTAssertEqual(configurationCodexRules(combined), configurationCodexRules(
            try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: nil,
                codexExecutablePath: codexPath,
                vsCodePluginHelperExecutablePath: vsCodePluginHelperPath
            )
        ))
    }

    func testProxyWebsiteOverrideRulesUseStableNormalizedHostnameOrder() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            proxyWebsiteHostnames: ["z.example.com", "a.example.com"]
        )

        let routeHostnames = configuration.route.rules.dropFirst(4).compactMap { rule in
            rule.action == "route" ? rule.overrideAddress : nil
        }
        XCTAssertEqual(routeHostnames, [
            "a.example.com",
            "a.example.com",
            "z.example.com",
            "z.example.com",
        ])
        XCTAssertEqual(
            Array(configuration.route.rules.dropFirst(4).map(\.destinationPort)),
            [80, 443, 80, 443]
        )
    }

    func testProxyWebsiteConfigurationPassesBundledSingBoxCheck() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for hostnames in [["chatgpt.com"], ["chatgpt.com", "example.com"]] {
            let configuration = try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: "/Applications/Google Chrome.app",
                proxyWebsiteHostnames: hostnames
            )
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SeparateProxy-Websites-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try configuration.encodedJSON().write(to: temporaryURL, options: .atomic)

            let process = Process()
            let output = Pipe()
            process.executableURL = projectURL.appendingPathComponent("bin/sing-box")
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

    private func configurationCodexRules(
        _ configuration: SingBoxConfiguration
    ) -> [SingBoxConfiguration.Route.Rule] {
        Array(configuration.route.rules.suffix(4))
    }

    private func assertChromeSniffRule(
        _ rule: SingBoxConfiguration.Route.Rule,
        network: String,
        port: UInt16,
        sniffer: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            rule.processPathRegex,
            [#"^/Applications/Google Chrome\.app/"#],
            file: file,
            line: line
        )
        XCTAssertEqual(rule.network, network, file: file, line: line)
        XCTAssertEqual(rule.destinationPort, port, file: file, line: line)
        XCTAssertEqual(rule.action, "sniff", file: file, line: line)
        XCTAssertEqual(rule.sniffer, [sniffer], file: file, line: line)
        XCTAssertNil(rule.overrideDestination, file: file, line: line)
        XCTAssertNil(rule.outbound, file: file, line: line)
    }

    private func assertChromeIPv6CompatibilityRule(
        _ rule: SingBoxConfiguration.Route.Rule,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rule.processPathRegex, [#"^/Applications/Google Chrome\.app/"#], file: file, line: line)
        XCTAssertEqual(rule.ipVersion, 6, file: file, line: line)
        XCTAssertEqual(rule.action, "reject", file: file, line: line)
        XCTAssertEqual(rule.method, "default", file: file, line: line)
        XCTAssertEqual(rule.noDrop, true, file: file, line: line)
        XCTAssertNil(rule.destinationPort, file: file, line: line)
        XCTAssertNil(rule.domains, file: file, line: line)
        XCTAssertNil(rule.network, file: file, line: line)
        XCTAssertNil(rule.protocolName, file: file, line: line)
        XCTAssertNil(rule.outbound, file: file, line: line)
    }

    private func assertChromeDomainRouteRule(
        _ rule: SingBoxConfiguration.Route.Rule,
        domains: [String],
        port: UInt16,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rule.processPathRegex, [#"^/Applications/Google Chrome\.app/"#], file: file, line: line)
        XCTAssertNil(rule.ipVersion, file: file, line: line)
        XCTAssertEqual(rule.destinationPort, port, file: file, line: line)
        XCTAssertEqual(rule.domains, domains, file: file, line: line)
        XCTAssertEqual(rule.overrideAddress, domains.first, file: file, line: line)
        XCTAssertEqual(rule.action, "route", file: file, line: line)
        XCTAssertEqual(rule.outbound, "outline", file: file, line: line)
        XCTAssertNil(rule.network, file: file, line: line)
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

    private func assertGitRules(
        sniffRule: SingBoxConfiguration.Route.Rule,
        routeRule: SingBoxConfiguration.Route.Rule,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectedRegex = [
            gitInstallation.httpsHelperEntryPath,
            gitInstallation.canonicalHTTPHelperPath,
        ].map { path in
            let escaped = NSRegularExpression.escapedPattern(for: path)
                .replacingOccurrences(of: #"\/"#, with: "/")
            return "^\(escaped)$"
        }

        XCTAssertEqual(sniffRule.processPathRegex, expectedRegex, file: file, line: line)
        XCTAssertTrue(sniffRule.processPathRegex.allSatisfy { $0.hasSuffix("$") })
        XCTAssertEqual(sniffRule.network, "tcp", file: file, line: line)
        XCTAssertEqual(sniffRule.destinationPort, 443, file: file, line: line)
        XCTAssertEqual(sniffRule.action, "sniff", file: file, line: line)
        XCTAssertEqual(sniffRule.sniffer, ["tls"], file: file, line: line)
        XCTAssertEqual(sniffRule.overrideDestination, true, file: file, line: line)
        XCTAssertNil(sniffRule.protocolName, file: file, line: line)
        XCTAssertNil(sniffRule.outbound, file: file, line: line)

        XCTAssertEqual(routeRule.processPathRegex, expectedRegex, file: file, line: line)
        XCTAssertEqual(routeRule.network, "tcp", file: file, line: line)
        XCTAssertEqual(routeRule.destinationPort, 443, file: file, line: line)
        XCTAssertEqual(routeRule.action, "route", file: file, line: line)
        XCTAssertEqual(routeRule.outbound, "outline", file: file, line: line)
        XCTAssertNil(routeRule.protocolName, file: file, line: line)
        XCTAssertNil(routeRule.sniffer, file: file, line: line)
        XCTAssertNil(routeRule.overrideDestination, file: file, line: line)
    }
}
