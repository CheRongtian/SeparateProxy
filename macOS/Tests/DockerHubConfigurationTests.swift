import Foundation
import XCTest
@testable import SeparateProxyCore

final class DockerHubConfigurationTests: XCTestCase {
    private let outline = OutlineAccessKey(
        server: "192.0.2.1",
        serverPort: 8388,
        method: "aes-256-gcm",
        password: "test-only-password"
    )
    private let chromePath = "/Applications/Google Chrome.app"
    private let codexPath = "/Users/test/.vscode/extensions/openai.chatgpt-1.2.3-darwin-arm64/bin/macos-aarch64/codex"
    private let vsCodePluginHelperPath = "/Users/test/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
    private let gitInstallation = AppleGitInstallation(
        developerDirectoryPath: "/Applications/Xcode.app/Contents/Developer",
        gitExecutablePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        httpsHelperEntryPath: "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-remote-https",
        canonicalHTTPHelperPath: "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-remote-http"
    )

    func testDockerHubDisabledKeepsExistingTargetsFieldForFieldUnchanged() throws {
        let baseline = try existingTargetsConfiguration()
        let disabled = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: chromePath,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            dockerHubInstallation: nil,
            proxyWebsiteHostnames: ["chatgpt.com"]
        )

        XCTAssertEqual(disabled, baseline)
        XCTAssertEqual(try disabled.encodedJSON(), try baseline.encodedJSON())
    }

    func testDockerHubRulesAppendAfterExistingTargetsWithoutChangingThem() throws {
        let baseline = try existingTargetsConfiguration()
        let combined = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: chromePath,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            dockerHubInstallation: dockerInstallation,
            proxyWebsiteHostnames: ["chatgpt.com"]
        )

        XCTAssertEqual(
            Array(combined.route.rules.prefix(baseline.route.rules.count)),
            baseline.route.rules
        )
        XCTAssertEqual(combined.route.rules.count, baseline.route.rules.count + 10)
        XCTAssertEqual(combined.route.final, "direct")
        XCTAssertEqual(combined.experimental, baseline.experimental)
    }

    func testDockerHubOnlyGeneratesExactBackendAndCLIRules() throws {
        let configuration = try dockerOnlyConfiguration()
        let rules = configuration.route.rules

        XCTAssertEqual(rules.count, 10)
        assertSniffRule(
            rules[0],
            executablePath: dockerInstallation.backendExecutablePath
        )
        for (index, hostname) in DockerHubRoutePolicy.backendHostnames.enumerated() {
            assertDomainRule(
                rules[index + 1],
                executablePath: dockerInstallation.backendExecutablePath,
                hostname: hostname
            )
        }

        let cliStart = DockerHubRoutePolicy.backendHostnames.count + 1
        assertSniffRule(
            rules[cliStart],
            executablePath: dockerInstallation.cliExecutablePath
        )
        for (index, hostname) in DockerHubRoutePolicy.cliHostnames.enumerated() {
            assertDomainRule(
                rules[cliStart + index + 1],
                executablePath: dockerInstallation.cliExecutablePath,
                hostname: hostname
            )
        }
        XCTAssertEqual(configuration.route.final, "direct")
    }

    func testDockerHubJSONUsesPortAndNeverDestinationPort() throws {
        let json = try XCTUnwrap(
            String(data: dockerOnlyConfiguration().encodedJSON(), encoding: .utf8)
        )

        XCTAssertTrue(json.contains(#""port" : 443"#))
        XCTAssertFalse(json.contains("destination_port"))
        XCTAssertFalse(json.contains("domain_suffix"))
        XCTAssertFalse(json.contains("override_destination"))
    }

    func testDockerHubRulesExcludeUnsupportedDomainsNetworksAndPorts() throws {
        let rules = try dockerOnlyConfiguration().route.rules
        let routedDomains = Set(rules.flatMap { $0.domains ?? [] })

        for excluded in [
            "auth.docker.com",
            "cdn.auth0.com",
            "ghcr.io",
            "quay.io",
            "registry.example.com",
        ] {
            XCTAssertFalse(routedDomains.contains(excluded))
        }
        XCTAssertTrue(rules.allSatisfy { $0.network == "tcp" })
        XCTAssertTrue(rules.allSatisfy { $0.destinationPort == 443 })
        XCTAssertFalse(rules.contains { $0.destinationPort == 80 })
        XCTAssertFalse(rules.contains { $0.destinationPort == 8443 })
    }

    func testDockerCLIHasOnlyDeviceLoginDomains() throws {
        let rules = try dockerOnlyConfiguration().route.rules
        let cliPattern = try exactRegex(for: dockerInstallation.cliExecutablePath)
        let cliDomains = rules
            .filter { $0.processPathRegex == [cliPattern] }
            .flatMap { $0.domains ?? [] }

        XCTAssertEqual(cliDomains, DockerHubRoutePolicy.cliHostnames)
        XCTAssertFalse(cliDomains.contains("registry-1.docker.io"))
        XCTAssertFalse(cliDomains.contains("auth.docker.io"))
        XCTAssertFalse(cliDomains.contains("api.docker.com"))
    }

    func testDockerRegexEscapesSpecialCharactersAndMatchesExactExecutable() throws {
        let installation = DockerHubInstallation(
            applicationBundlePath: "/Applications/Dev Tools/Docker (Stable).app",
            backendExecutablePath: "/Applications/Dev Tools/Docker (Stable).app/Contents/MacOS/com.docker.backend",
            cliExecutablePath: "/Applications/Dev Tools/Docker (Stable).app/Contents/Resources/bin/docker"
        )
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            dockerHubInstallation: installation
        )
        let backendExpression = try NSRegularExpression(
            pattern: try XCTUnwrap(configuration.route.rules[0].processPathRegex.first)
        )
        let cliIndex = DockerHubRoutePolicy.backendHostnames.count + 1
        let cliExpression = try NSRegularExpression(
            pattern: try XCTUnwrap(configuration.route.rules[cliIndex].processPathRegex.first)
        )

        XCTAssertEqual(matches(backendExpression, installation.backendExecutablePath), 1)
        XCTAssertEqual(matches(backendExpression, installation.backendExecutablePath + ".old"), 0)
        XCTAssertEqual(matches(cliExpression, installation.cliExecutablePath), 1)
        XCTAssertEqual(matches(cliExpression, "/usr/local/bin/docker"), 0)
    }

    func testInvalidDockerHubInstallationIsRejected() {
        let invalid = DockerHubInstallation(
            applicationBundlePath: dockerInstallation.applicationBundlePath,
            backendExecutablePath: dockerInstallation.backendExecutablePath,
            cliExecutablePath: "/usr/local/bin/docker"
        )

        XCTAssertThrowsError(try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            dockerHubInstallation: invalid
        )) { error in
            XCTAssertEqual(
                error as? SingBoxConfigurationError,
                .invalidDockerHubInstallation
            )
        }
    }

    func testEnabledDiscoveryFailureIsAtomicBeforeConfigurationGeneration() {
        XCTAssertThrowsError(try DockerHubDiscovery.resolveIfEnabled(true) {
            throw DockerHubDiscoveryError.notInstalled
        }) { error in
            XCTAssertEqual(error as? DockerHubDiscoveryError, .notInstalled)
        }
    }

    func testSyntheticDockerHubConfigurationPassesBundledSingBoxCheck() throws {
        let configuration = try dockerOnlyConfiguration()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-DockerHub-\(UUID().uuidString).json")
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

    private var dockerInstallation: DockerHubInstallation {
        DockerHubInstallation(
            applicationBundlePath: "/Applications/Docker Desktop (Stable).app",
            backendExecutablePath: "/Applications/Docker Desktop (Stable).app/Contents/MacOS/com.docker.backend",
            cliExecutablePath: "/Applications/Docker Desktop (Stable).app/Contents/Resources/bin/docker"
        )
    }

    private func existingTargetsConfiguration() throws -> SingBoxConfiguration {
        try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: chromePath,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            proxyWebsiteHostnames: ["chatgpt.com"]
        )
    }

    private func dockerOnlyConfiguration() throws -> SingBoxConfiguration {
        try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            dockerHubInstallation: dockerInstallation
        )
    }

    private func assertSniffRule(
        _ rule: SingBoxConfiguration.Route.Rule,
        executablePath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rule.processPathRegex, [try! exactRegex(for: executablePath)], file: file, line: line)
        XCTAssertEqual(rule.network, "tcp", file: file, line: line)
        XCTAssertEqual(rule.destinationPort, 443, file: file, line: line)
        XCTAssertEqual(rule.action, "sniff", file: file, line: line)
        XCTAssertEqual(rule.sniffer, ["tls"], file: file, line: line)
        XCTAssertNil(rule.overrideDestination, file: file, line: line)
        XCTAssertNil(rule.protocolName, file: file, line: line)
        XCTAssertNil(rule.domains, file: file, line: line)
        XCTAssertNil(rule.overrideAddress, file: file, line: line)
        XCTAssertNil(rule.outbound, file: file, line: line)
    }

    private func assertDomainRule(
        _ rule: SingBoxConfiguration.Route.Rule,
        executablePath: String,
        hostname: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rule.processPathRegex, [try! exactRegex(for: executablePath)], file: file, line: line)
        XCTAssertEqual(rule.network, "tcp", file: file, line: line)
        XCTAssertEqual(rule.destinationPort, 443, file: file, line: line)
        XCTAssertEqual(rule.protocolName, "tls", file: file, line: line)
        XCTAssertEqual(rule.domains, [hostname], file: file, line: line)
        XCTAssertEqual(rule.action, "route", file: file, line: line)
        XCTAssertEqual(rule.overrideAddress, hostname, file: file, line: line)
        XCTAssertEqual(rule.outbound, "outline", file: file, line: line)
        XCTAssertNil(rule.sniffer, file: file, line: line)
        XCTAssertNil(rule.overrideDestination, file: file, line: line)
    }

    private func exactRegex(for path: String) throws -> String {
        let escaped = NSRegularExpression.escapedPattern(for: path)
            .replacingOccurrences(of: #"\/"#, with: "/")
        return "^\(escaped)$"
    }

    private func matches(_ expression: NSRegularExpression, _ value: String) -> Int {
        expression.numberOfMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
    }
}
