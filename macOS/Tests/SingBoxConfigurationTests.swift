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
    private let dockerInstallation = DockerHubInstallation(
        applicationBundlePath: "/Applications/Docker.app",
        backendExecutablePath: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
        cliExecutablePath: "/Applications/Docker.app/Contents/Resources/bin/docker"
    )

    func testEmptyProxyWebsiteListKeepsChromeIPv6RuleAndAppendsDirectIPv6Guard() throws {
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
        assertChromeIPv6CompatibilityRule(configuration.route.rules[0])
        assertDirectIPv6FallbackGuard(configuration)
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

        let baselineRules = Array(baseline.route.rules.dropLast())
        XCTAssertEqual(Array(combined.route.rules.prefix(baselineRules.count)), baselineRules)
        XCTAssertEqual(combined.route.rules.count, baseline.route.rules.count + 4)
        let codexStart = baselineRules.count
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
        assertDirectIPv6FallbackGuard(combined)
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

        let baselineRules = Array(baseline.route.rules.dropLast())
        XCTAssertEqual(Array(combined.route.rules.prefix(baselineRules.count)), baselineRules)
        XCTAssertEqual(combined.route.rules.count, baseline.route.rules.count + 2)
        assertGitRules(
            sniffRule: combined.route.rules[baselineRules.count],
            routeRule: combined.route.rules[baselineRules.count + 1]
        )
        assertDirectIPv6FallbackGuard(combined)
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

        XCTAssertEqual(configuration.route.rules.count, 3)
        assertGitRules(
            sniffRule: configuration.route.rules[0],
            routeRule: configuration.route.rules[1]
        )
        assertDirectIPv6FallbackGuard(configuration)
    }

    func testGitRegexDoesNotMatchExcludedExecutables() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            gitInstallation: gitInstallation
        )
        let expressions = try XCTUnwrap(configuration.route.rules[0].processPathRegex).map {
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

        XCTAssertEqual(configuration.route.rules.count, 5)
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
        assertDirectIPv6FallbackGuard(configuration)
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
            configuration.route.rules.first?.processPathRegex?.first
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
        XCTAssertEqual(rules[0]["process_path_regex"] as? [String], [#"^/Applications/Google Chrome\.app/"#])
        XCTAssertEqual(rules[0]["ip_version"] as? Int, 6)
        XCTAssertEqual(rules[0]["action"] as? String, "reject")
        XCTAssertEqual(rules[0]["method"] as? String, "default")
        XCTAssertEqual(rules[0]["no_drop"] as? Bool, true)
        XCTAssertNil(rules[0]["domain"])
        XCTAssertNil(rules[0]["port"])
        XCTAssertNil(rules[0]["network"])
        XCTAssertNil(rules[0]["outbound"])
        XCTAssertNil(rules[1]["process_path_regex"])
        XCTAssertEqual(rules[1]["ip_version"] as? Int, 6)
        XCTAssertEqual(rules[1]["action"] as? String, "reject")
        XCTAssertEqual(rules[1]["method"] as? String, "default")
        XCTAssertEqual(rules[1]["no_drop"] as? Bool, true)
        XCTAssertNil(rules[1]["domain"])
        XCTAssertNil(rules[1]["port"])
        XCTAssertNil(rules[1]["network"])
        XCTAssertNil(rules[1]["outbound"])
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

        XCTAssertEqual(rules.count, 5)
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
        XCTAssertNil(rules[4]["process_path_regex"])
        XCTAssertEqual(rules[4]["ip_version"] as? Int, 6)
        XCTAssertEqual(rules[4]["action"] as? String, "reject")
        XCTAssertEqual(rules[4]["no_drop"] as? Bool, true)
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

        XCTAssertEqual(configuration.route.rules.count, 9)
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
        assertDirectIPv6FallbackGuard(configuration)
        XCTAssertFalse(configuration.route.rules.contains { rule in
            rule.action == "route" && rule.domains == nil
        })
        XCTAssertEqual(
            configuration.route.rules.filter { $0.action == "reject" }.count,
            2
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

        let chromeRules = Array(chromeOnly.route.rules.dropLast())
        XCTAssertEqual(Array(combined.route.rules.prefix(chromeRules.count)), chromeRules)
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

        let websiteRules = configuration.route.rules.dropFirst(4).dropLast()
        let routeHostnames = websiteRules.compactMap { rule in
            rule.action == "route" ? rule.overrideAddress : nil
        }
        XCTAssertEqual(routeHostnames, [
            "a.example.com",
            "a.example.com",
            "z.example.com",
            "z.example.com",
        ])
        XCTAssertEqual(
            Array(websiteRules.map(\.destinationPort)),
            [80, 443, 80, 443]
        )
    }

    func testGoogleDisabledIsFieldForFieldEqualToExistingChromeConfigurations() throws {
        let emptyBaseline = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app"
        )
        let emptyEffective = try GoogleWebsiteRouting.effectiveHostnames(
            customHostnames: [],
            isEnabled: false
        )
        let emptyDisabled = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            proxyWebsiteHostnames: emptyEffective
        )
        XCTAssertEqual(emptyDisabled, emptyBaseline)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: emptyDisabled.encodedJSON()) as? NSDictionary,
            try JSONSerialization.jsonObject(with: emptyBaseline.encodedJSON()) as? NSDictionary
        )

        let customBaseline = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            proxyWebsiteHostnames: ["chatgpt.com"]
        )
        let customEffective = try GoogleWebsiteRouting.effectiveHostnames(
            customHostnames: ["chatgpt.com"],
            isEnabled: false
        )
        let customDisabled = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            proxyWebsiteHostnames: customEffective
        )
        XCTAssertEqual(customDisabled, customBaseline)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: customDisabled.encodedJSON()) as? NSDictionary,
            try JSONSerialization.jsonObject(with: customBaseline.encodedJSON()) as? NSDictionary
        )
    }

    func testGoogleWebsiteRoutingUsesExistingExactHostnameRuleShape() throws {
        let effective = try GoogleWebsiteRouting.effectiveHostnames(
            customHostnames: [],
            isEnabled: true
        )
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            proxyWebsiteHostnames: effective
        )

        XCTAssertEqual(configuration.route.rules.count, 1 + 3 + (11 * 2) + 1)
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

        for (index, hostname) in effective.enumerated() {
            let routeStart = 4 + (index * 2)
            assertChromeDomainRouteRule(
                configuration.route.rules[routeStart],
                domains: [hostname],
                port: 80
            )
            assertChromeDomainRouteRule(
                configuration.route.rules[routeStart + 1],
                domains: [hostname],
                port: 443
            )
        }
        assertDirectIPv6FallbackGuard(configuration)

        let json = try XCTUnwrap(
            String(data: configuration.encodedJSON(), encoding: .utf8)
        )
        XCTAssertFalse(json.contains("domain_suffix"))
        XCTAssertFalse(json.contains("*.google.com"))
    }

    func testGoogleAndCustomDuplicateGeneratesOneExactHostnameRulePair() throws {
        let effective = try GoogleWebsiteRouting.effectiveHostnames(
            customHostnames: ["accounts.google.com"],
            isEnabled: true
        )
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            proxyWebsiteHostnames: effective
        )
        let accountRules = configuration.route.rules.filter {
            $0.domains == ["accounts.google.com"]
        }

        XCTAssertEqual(effective.count, 11)
        XCTAssertEqual(accountRules.count, 2)
        XCTAssertEqual(accountRules.map(\.destinationPort), [80, 443])
    }

    func testGoogleWebsiteRulesPrecedeUnchangedCodexAndGitRules() throws {
        let effective = try GoogleWebsiteRouting.effectiveHostnames(
            customHostnames: ["example.com"],
            isEnabled: true
        )
        let chromeOnly = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            proxyWebsiteHostnames: effective
        )
        let additionalOnly = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation
        )
        let combined = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            proxyWebsiteHostnames: effective
        )

        let chromeRules = Array(chromeOnly.route.rules.dropLast())
        let additionalRules = Array(additionalOnly.route.rules.dropLast())
        XCTAssertEqual(Array(combined.route.rules.prefix(chromeRules.count)), chromeRules)
        XCTAssertEqual(
            Array(combined.route.rules.dropFirst(chromeRules.count).dropLast()),
            additionalRules
        )
        assertDirectIPv6FallbackGuard(combined)
    }

    func testSyntheticGoogleWebsiteConfigurationPassesBundledSingBoxCheck() throws {
        let effective = try GoogleWebsiteRouting.effectiveHostnames(
            customHostnames: ["example.com"],
            isEnabled: true
        )
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            proxyWebsiteHostnames: effective
        )
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-Google-Websites-\(UUID().uuidString).json")
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
        let pattern = try XCTUnwrap(configuration.route.rules[2].processPathRegex?.first)
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

    func testDirectIPv6FallbackGuardIsUniqueAndLastAcrossTargetMatrix() throws {
        let configurations: [(String, SingBoxConfiguration)] = [
            (
                "Chrome",
                try SingBoxConfigurationBuilder.make(
                    outline: outline,
                    chromeBundlePath: "/Applications/Google Chrome.app"
                )
            ),
            (
                "Codex",
                try SingBoxConfigurationBuilder.make(
                    outline: outline,
                    chromeBundlePath: nil,
                    codexExecutablePath: codexPath,
                    vsCodePluginHelperExecutablePath: vsCodePluginHelperPath
                )
            ),
            (
                "Git",
                try SingBoxConfigurationBuilder.make(
                    outline: outline,
                    chromeBundlePath: nil,
                    codexExecutablePath: nil,
                    vsCodePluginHelperExecutablePath: nil,
                    gitInstallation: gitInstallation
                )
            ),
            (
                "Docker Hub",
                try SingBoxConfigurationBuilder.make(
                    outline: outline,
                    chromeBundlePath: nil,
                    codexExecutablePath: nil,
                    vsCodePluginHelperExecutablePath: nil,
                    dockerHubInstallation: dockerInstallation
                )
            ),
            (
                "Homebrew",
                try SingBoxConfigurationBuilder.make(
                    outline: outline,
                    chromeBundlePath: nil,
                    codexExecutablePath: nil,
                    vsCodePluginHelperExecutablePath: nil,
                    homebrewEnabled: true,
                    homebrewGitInstallation: gitInstallation
                )
            ),
            (
                "Kubernetes",
                try SingBoxConfigurationBuilder.make(
                    outline: outline,
                    chromeBundlePath: nil,
                    codexExecutablePath: nil,
                    vsCodePluginHelperExecutablePath: nil,
                    kubernetesInstallation: dockerInstallation.backendInstallation
                )
            ),
            (
                "Docker Hub + Kubernetes",
                try SingBoxConfigurationBuilder.make(
                    outline: outline,
                    chromeBundlePath: nil,
                    codexExecutablePath: nil,
                    vsCodePluginHelperExecutablePath: nil,
                    dockerHubInstallation: dockerInstallation,
                    kubernetesInstallation: dockerInstallation.backendInstallation
                )
            ),
            ("All targets", try allTargetsConfiguration()),
        ]

        for (name, configuration) in configurations {
            assertDirectIPv6FallbackGuard(configuration, file: #filePath, line: #line)
            XCTAssertFalse(configuration.route.rules.dropLast().isEmpty, name)
        }
    }

    func testNonTargetIPv6ReachesGuardWhileIPv4ReachesFinalDirect() throws {
        let configuration = try allTargetsConfiguration()
        let writerHelperPath = "/Applications/作家助手.app/Contents/Frameworks/作家助手 Helper.app/Contents/MacOS/作家助手 Helper"

        let ipv6Rule = try XCTUnwrap(firstMatchingRule(
            processPath: writerHelperPath,
            ipVersion: 6,
            in: configuration.route.rules
        ))
        XCTAssertEqual(ipv6Rule, configuration.route.rules.last)
        assertDirectIPv6FallbackGuard(configuration)

        XCTAssertNil(try firstMatchingRule(
            processPath: writerHelperPath,
            ipVersion: 4,
            in: configuration.route.rules
        ))
        XCTAssertEqual(configuration.route.final, "direct")
    }

    func testExplicitOutlineTargetsRemainBeforeDirectIPv6FallbackGuard() throws {
        let configuration = try allTargetsConfiguration()
        let rules = configuration.route.rules
        let guardIndex = rules.index(before: rules.endIndex)
        let targetRouteIndexes = [
            try XCTUnwrap(rules.firstIndex {
                $0.action == "route"
                    && $0.outbound == "outline"
                    && $0.processPathRegex?.contains(where: { $0.contains("/codex$") }) == true
            }),
            try XCTUnwrap(rules.firstIndex {
                $0.action == "route"
                    && $0.outbound == "outline"
                    && $0.processPathRegex?.contains(where: { $0.contains("git-remote-https") }) == true
            }),
            try XCTUnwrap(rules.firstIndex { $0.domains == ["registry-1.docker.io"] }),
            try XCTUnwrap(rules.firstIndex { $0.domains == ["registry.k8s.io"] }),
            try XCTUnwrap(rules.firstIndex { $0.domains == ["formulae.brew.sh"] }),
        ]

        XCTAssertTrue(targetRouteIndexes.allSatisfy { $0 < guardIndex })
        assertChromeIPv6CompatibilityRule(rules[0])
        assertDirectIPv6FallbackGuard(configuration)
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

    private func allTargetsConfiguration() throws -> SingBoxConfiguration {
        try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            dockerHubInstallation: dockerInstallation,
            kubernetesInstallation: dockerInstallation.backendInstallation,
            containerRegistriesInstallation: dockerInstallation.backendInstallation,
            homebrewEnabled: true,
            proxyWebsiteHostnames: ["chatgpt.com"]
        )
    }

    private func firstMatchingRule(
        processPath: String,
        ipVersion: Int,
        in rules: [SingBoxConfiguration.Route.Rule]
    ) throws -> SingBoxConfiguration.Route.Rule? {
        for rule in rules {
            if let ruleIPVersion = rule.ipVersion, ruleIPVersion != ipVersion {
                continue
            }
            if let patterns = rule.processPathRegex {
                let processMatches = try patterns.contains { pattern in
                    let expression = try NSRegularExpression(pattern: pattern)
                    return numberOfMatches(expression, in: processPath) > 0
                }
                if !processMatches {
                    continue
                }
            }
            return rule
        }
        return nil
    }

    private func configurationCodexRules(
        _ configuration: SingBoxConfiguration
    ) -> [SingBoxConfiguration.Route.Rule] {
        Array(configuration.route.rules.dropLast().suffix(4))
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

    private func assertDirectIPv6FallbackGuard(
        _ configuration: SingBoxConfiguration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matchingGuards = configuration.route.rules.filter { rule in
            rule.processPathRegex == nil
                && rule.ipVersion == 6
                && rule.action == "reject"
                && rule.method == "default"
                && rule.noDrop == true
                && rule.network == nil
                && rule.destinationPort == nil
                && rule.sniffer == nil
                && rule.overrideDestination == nil
                && rule.protocolName == nil
                && rule.domains == nil
                && rule.overrideAddress == nil
                && rule.outbound == nil
        }

        XCTAssertEqual(matchingGuards.count, 1, file: file, line: line)
        XCTAssertEqual(configuration.route.rules.last, matchingGuards.first, file: file, line: line)
        XCTAssertEqual(configuration.route.final, "direct", file: file, line: line)
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
        XCTAssertTrue(sniffRule.processPathRegex?.allSatisfy { $0.hasSuffix("$") } ?? false)
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
