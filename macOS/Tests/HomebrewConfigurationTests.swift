import Foundation
import XCTest
@testable import SeparateProxyCore

final class HomebrewConfigurationTests: XCTestCase {
    private let outline = OutlineAccessKey(
        server: "192.0.2.1",
        serverPort: 8388,
        method: "aes-256-gcm",
        password: "test-only-password"
    )
    private let codexPath = "/Users/test/.vscode/extensions/openai.chatgpt-1.2.3-darwin-arm64/bin/macos-aarch64/codex"
    private let vsCodePluginHelperPath = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
    private let gitInstallation = AppleGitInstallation(
        developerDirectoryPath: "/Applications/Xcode.app/Contents/Developer",
        gitExecutablePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        httpsHelperEntryPath: "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-remote-https",
        canonicalHTTPHelperPath: "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-remote-http"
    )
    private let dockerHubInstallation = DockerHubInstallation(
        applicationBundlePath: "/Applications/Docker.app",
        backendExecutablePath: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
        cliExecutablePath: "/Applications/Docker.app/Contents/Resources/bin/docker"
    )

    func testHomebrewOffGitOffDoesNotCreateAConfiguration() {
        XCTAssertThrowsError(try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            gitInstallation: nil,
            homebrewEnabled: false
        )) { error in
            XCTAssertEqual(error as? SingBoxConfigurationError, .noTargetsSelected)
        }
    }

    func testHomebrewDisabledIsFieldForFieldEqualToExistingBaseline() throws {
        let baseline = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            dockerHubInstallation: dockerHubInstallation
        )
        let disabled = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            dockerHubInstallation: dockerHubInstallation,
            homebrewEnabled: false,
            homebrewGitInstallation: nil
        )

        XCTAssertEqual(disabled, baseline)
        XCTAssertEqual(try disabled.encodedJSON(), try baseline.encodedJSON())
        XCTAssertEqual(disabled.route.final, "direct")
    }

    func testHomebrewOnGitOffAddsExactCurlAndScopedGitRules() throws {
        let configuration = try makeHomebrewConfiguration(
            gitInstallation: nil,
            homebrewGitInstallation: gitInstallation
        )

        let targetRules = Array(configuration.route.rules.dropLast())
        XCTAssertEqual(configuration.route.rules.count, 8)
        assertCurlRules(Array(targetRules.prefix(5)))
        assertScopedGitRules(Array(targetRules.suffix(2)))
        XCTAssertEqual(configuration.route.final, "direct")
    }

    func testGitOnHomebrewOffKeepsExistingGitConfigurationUnchanged() throws {
        let baseline = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            gitInstallation: gitInstallation
        )
        let disabled = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            gitInstallation: gitInstallation,
            homebrewEnabled: false
        )

        XCTAssertEqual(disabled, baseline)
        XCTAssertEqual(disabled.route.rules.count, 3)
    }

    func testGitOnHomebrewOnKeepsGitRulesAndAvoidsDuplicateScopedGitRules() throws {
        let gitOnly = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            gitInstallation: gitInstallation
        )
        let combined = try makeHomebrewConfiguration(
            gitInstallation: gitInstallation,
            homebrewGitInstallation: nil
        )

        XCTAssertEqual(
            Array(combined.route.rules.prefix(2)),
            Array(gitOnly.route.rules.dropLast())
        )
        XCTAssertEqual(combined.route.rules.count, 8)
        assertCurlRules(Array(combined.route.rules.dropLast().suffix(5)))
        XCTAssertFalse(combined.route.rules.contains {
            $0.domains == [HomebrewRoutePolicy.gitHostname]
        })
        let gitSniffRules = combined.route.rules.filter {
            $0.processPathRegex == gitOnly.route.rules[0].processPathRegex
                && $0.action == "sniff"
        }
        XCTAssertEqual(gitSniffRules.count, 1)
        XCTAssertEqual(gitSniffRules[0].overrideDestination, true)
    }

    func testHomebrewDoesNotRouteExcludedCurlHosts() throws {
        let configuration = try makeHomebrewConfiguration(
            gitInstallation: nil,
            homebrewGitInstallation: gitInstallation
        )
        let routedDomains = Set(configuration.route.rules.compactMap { $0.domains?.first })

        for excluded in [
            "raw.githubusercontent.com",
            "objects.githubusercontent.com",
            "analytics.brew.sh",
            "brew.sh",
            "example.com",
            "gitlab.com",
        ] {
            XCTAssertFalse(routedDomains.contains(excluded))
        }
    }

    func testHomebrewRulesAppendAfterExistingChromeCodexGitAndDockerRules() throws {
        let baseline = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            dockerHubInstallation: dockerHubInstallation
        )
        let combined = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: "/Applications/Google Chrome.app",
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            dockerHubInstallation: dockerHubInstallation,
            homebrewEnabled: true
        )

        let baselineRules = Array(baseline.route.rules.dropLast())
        XCTAssertEqual(Array(combined.route.rules.prefix(baselineRules.count)), baselineRules)
        assertCurlRules(Array(combined.route.rules.dropLast().suffix(5)))
        XCTAssertEqual(combined.route.final, "direct")
        XCTAssertEqual(combined.experimental, baseline.experimental)
    }

    func testSyntheticHomebrewCombinationsPassBundledSingBoxCheck() throws {
        let configurations = [
            try makeHomebrewConfiguration(
                gitInstallation: nil,
                homebrewGitInstallation: gitInstallation
            ),
            try makeHomebrewConfiguration(
                gitInstallation: gitInstallation,
                homebrewGitInstallation: nil
            ),
            try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: nil,
                codexExecutablePath: nil,
                vsCodePluginHelperExecutablePath: nil,
                dockerHubInstallation: dockerHubInstallation,
                homebrewEnabled: true,
                homebrewGitInstallation: gitInstallation
            ),
            try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: nil,
                codexExecutablePath: codexPath,
                vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
                homebrewEnabled: true,
                homebrewGitInstallation: gitInstallation
            ),
            try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: "/Applications/Google Chrome.app",
                codexExecutablePath: nil,
                vsCodePluginHelperExecutablePath: nil,
                homebrewEnabled: true,
                homebrewGitInstallation: gitInstallation
            ),
        ]

        for configuration in configurations {
            try assertPassesBundledSingBoxCheck(configuration)
        }
    }

    private func makeHomebrewConfiguration(
        gitInstallation: AppleGitInstallation?,
        homebrewGitInstallation: AppleGitInstallation?
    ) throws -> SingBoxConfiguration {
        try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            gitInstallation: gitInstallation,
            homebrewEnabled: true,
            homebrewGitInstallation: homebrewGitInstallation
        )
    }

    private func assertCurlRules(
        _ rules: [SingBoxConfiguration.Route.Rule],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rules.count, 5, file: file, line: line)
        guard rules.count == 5 else { return }
        XCTAssertEqual(
            HomebrewRoutePolicy.curlHostnames,
            [
                "formulae.brew.sh",
                "ghcr.io",
                "pkg-containers.githubusercontent.com",
                "api.github.com",
            ],
            file: file,
            line: line
        )

        let curlRegex = [#"^/usr/bin/curl$"#]
        let sniff = rules[0]
        XCTAssertEqual(sniff.processPathRegex, curlRegex, file: file, line: line)
        XCTAssertEqual(sniff.network, "tcp", file: file, line: line)
        XCTAssertEqual(sniff.destinationPort, 443, file: file, line: line)
        XCTAssertEqual(sniff.action, "sniff", file: file, line: line)
        XCTAssertEqual(sniff.sniffer, ["tls"], file: file, line: line)
        XCTAssertNotEqual(sniff.overrideDestination, true, file: file, line: line)
        XCTAssertNil(sniff.outbound, file: file, line: line)

        for (rule, hostname) in zip(rules.dropFirst(), HomebrewRoutePolicy.curlHostnames) {
            XCTAssertEqual(rule.processPathRegex, curlRegex, file: file, line: line)
            XCTAssertEqual(rule.network, "tcp", file: file, line: line)
            XCTAssertEqual(rule.destinationPort, 443, file: file, line: line)
            XCTAssertEqual(rule.protocolName, "tls", file: file, line: line)
            XCTAssertEqual(rule.domains, [hostname], file: file, line: line)
            XCTAssertEqual(rule.overrideAddress, hostname, file: file, line: line)
            XCTAssertEqual(rule.action, "route", file: file, line: line)
            XCTAssertEqual(rule.outbound, "outline", file: file, line: line)
        }
    }

    private func assertScopedGitRules(
        _ rules: [SingBoxConfiguration.Route.Rule],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rules.count, 2, file: file, line: line)
        guard rules.count == 2 else { return }
        XCTAssertEqual(rules[0].network, "tcp", file: file, line: line)
        XCTAssertEqual(rules[0].destinationPort, 443, file: file, line: line)
        XCTAssertEqual(rules[0].action, "sniff", file: file, line: line)
        XCTAssertEqual(rules[0].sniffer, ["tls"], file: file, line: line)
        XCTAssertNotEqual(rules[0].overrideDestination, true, file: file, line: line)

        XCTAssertEqual(rules[1].processPathRegex, rules[0].processPathRegex, file: file, line: line)
        XCTAssertEqual(rules[1].network, "tcp", file: file, line: line)
        XCTAssertEqual(rules[1].destinationPort, 443, file: file, line: line)
        XCTAssertEqual(rules[1].protocolName, "tls", file: file, line: line)
        XCTAssertEqual(HomebrewRoutePolicy.gitHostname, "github.com", file: file, line: line)
        XCTAssertEqual(rules[1].domains, ["github.com"], file: file, line: line)
        XCTAssertEqual(rules[1].overrideAddress, "github.com", file: file, line: line)
        XCTAssertEqual(rules[1].action, "route", file: file, line: line)
        XCTAssertEqual(rules[1].outbound, "outline", file: file, line: line)
    }

    private func assertPassesBundledSingBoxCheck(
        _ configuration: SingBoxConfiguration
    ) throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-Homebrew-\(UUID().uuidString).json")
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
}
