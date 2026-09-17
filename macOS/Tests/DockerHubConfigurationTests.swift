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
        let disabledJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: disabled.encodedJSON()) as? NSDictionary
        )
        let baselineJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: baseline.encodedJSON()) as? NSDictionary
        )
        XCTAssertEqual(disabledJSON, baselineJSON)
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

    func testGoogleWebsiteRoutingDoesNotChangeDockerHubRules() throws {
        let effective = try GoogleWebsiteRouting.effectiveHostnames(
            customHostnames: ["example.com"],
            isEnabled: true
        )
        let baseline = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: chromePath,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            proxyWebsiteHostnames: effective
        )
        let combined = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: chromePath,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            dockerHubInstallation: dockerInstallation,
            proxyWebsiteHostnames: effective
        )
        let dockerOnly = try dockerOnlyConfiguration()

        XCTAssertEqual(
            Array(combined.route.rules.prefix(baseline.route.rules.count)),
            baseline.route.rules
        )
        XCTAssertEqual(
            Array(combined.route.rules.dropFirst(baseline.route.rules.count)),
            dockerOnly.route.rules
        )
        XCTAssertEqual(combined.route.final, "direct")
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

    func testDockerKubernetesAndContainerRegistriesDisabledProduceNoBackendRules() throws {
        let configuration = try existingTargetsConfiguration()
        let backendPattern = try exactRegex(for: dockerInstallation.backendExecutablePath)
        let routedDomains = configuration.route.rules.flatMap { $0.domains ?? [] }

        XCTAssertFalse(
            configuration.route.rules.contains { $0.processPathRegex == [backendPattern] }
        )
        XCTAssertFalse(routedDomains.contains("gcr.io"))
    }

    func testKubernetesOnlyGeneratesExactBackendRules() throws {
        let configuration = try kubernetesOnlyConfiguration()
        let rules = configuration.route.rules

        XCTAssertEqual(rules.count, KubernetesRoutePolicy.backendHostnames.count + 1)
        assertSniffRule(
            rules[0],
            executablePath: dockerInstallation.backendExecutablePath
        )
        for (index, hostname) in KubernetesRoutePolicy.backendHostnames.enumerated() {
            assertDomainRule(
                rules[index + 1],
                executablePath: dockerInstallation.backendExecutablePath,
                hostname: hostname
            )
        }
        XCTAssertEqual(configuration.route.final, "direct")
    }

    func testKubernetesArtifactRegistryCatalogIsCompleteAndRepresentative() {
        XCTAssertEqual(KubernetesRoutePolicy.artifactRegistryLocations.count, 46)
        XCTAssertEqual(KubernetesRoutePolicy.artifactRegistryHostnames.count, 46)
        for hostname in [
            "us-east1-docker.pkg.dev",
            "us-west1-docker.pkg.dev",
            "us-central1-docker.pkg.dev",
            "europe-west1-docker.pkg.dev",
            "asia-east1-docker.pkg.dev",
            "us-docker.pkg.dev",
            "europe-docker.pkg.dev",
            "asia-docker.pkg.dev",
        ] {
            XCTAssertTrue(KubernetesRoutePolicy.artifactRegistryHostnames.contains(hostname))
        }
    }

    func testKubernetesRulesExcludeUnrelatedAndLegacyRegistries() throws {
        let routedDomains = Set(
            try kubernetesOnlyConfiguration().route.rules.flatMap { $0.domains ?? [] }
        )

        for excluded in [
            "example.com",
            "google.com",
            "googleapis.com",
            "googleusercontent.com",
            "storage.googleapis.com",
            "ghcr.io",
            "quay.io",
            "gcr.io",
            "k8s.gcr.io",
            "registry.example.com",
            "evil-docker.pkg.dev",
        ] {
            XCTAssertFalse(routedDomains.contains(excluded))
        }
    }

    func testKubernetesRulesUseExactDomainsWithoutWildcardOrDestinationOverride() throws {
        let configuration = try kubernetesOnlyConfiguration()
        let json = try XCTUnwrap(
            String(data: configuration.encodedJSON(), encoding: .utf8)
        )

        XCTAssertFalse(json.contains("domain_suffix"))
        XCTAssertFalse(json.contains("domain_regex"))
        XCTAssertFalse(json.contains("*.docker.pkg.dev"))
        XCTAssertFalse(json.contains("override_destination"))
        XCTAssertTrue(configuration.route.rules.allSatisfy { $0.network == "tcp" })
        XCTAssertTrue(configuration.route.rules.allSatisfy { $0.destinationPort == 443 })
    }

    func testDockerAndKubernetesShareOneBackendSniffAndDeterministicUnion() throws {
        let configuration = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            dockerHubInstallation: dockerInstallation,
            kubernetesInstallation: dockerInstallation
        )
        let backendPattern = try exactRegex(for: dockerInstallation.backendExecutablePath)
        let backendRules = configuration.route.rules.filter {
            $0.processPathRegex == [backendPattern]
        }
        let backendSniffs = backendRules.filter { $0.action == "sniff" }
        let routedDomains = backendRules.flatMap { $0.domains ?? [] }
        let expectedDomains = DockerHubRoutePolicy.backendHostnames
            + KubernetesRoutePolicy.backendHostnames

        XCTAssertEqual(backendSniffs.count, 1)
        XCTAssertEqual(routedDomains, expectedDomains)
        XCTAssertEqual(Set(routedDomains).count, routedDomains.count)
        XCTAssertEqual(
            configuration.route.rules.count,
            1 + expectedDomains.count + 1 + DockerHubRoutePolicy.cliHostnames.count
        )
    }

    func testKubernetesOnlyDoesNotGenerateDockerCLIRules() throws {
        let configuration = try kubernetesOnlyConfiguration()
        let cliPattern = try exactRegex(for: dockerInstallation.cliExecutablePath)

        XCTAssertFalse(
            configuration.route.rules.contains { $0.processPathRegex == [cliPattern] }
        )
    }

    func testKubernetesRulesDoNotChangeOtherTargetRules() throws {
        let baseline = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: chromePath,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            homebrewEnabled: true,
            proxyWebsiteHostnames: ["chatgpt.com"]
        )
        let combined = try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: chromePath,
            codexExecutablePath: codexPath,
            vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
            gitInstallation: gitInstallation,
            kubernetesInstallation: dockerInstallation,
            homebrewEnabled: true,
            proxyWebsiteHostnames: ["chatgpt.com"]
        )
        let backendPattern = try exactRegex(for: dockerInstallation.backendExecutablePath)
        let combinedWithoutKubernetes = combined.route.rules.filter {
            $0.processPathRegex != [backendPattern]
        }

        XCTAssertEqual(combinedWithoutKubernetes, baseline.route.rules)
        XCTAssertEqual(combined.route.final, baseline.route.final)
        XCTAssertEqual(combined.experimental, baseline.experimental)
    }

    func testContainerRegistriesOnlyGeneratesExactGCRRoute() throws {
        let configuration = try containerRegistriesOnlyConfiguration()
        let rules = configuration.route.rules

        XCTAssertEqual(rules.count, 2)
        assertSniffRule(
            rules[0],
            executablePath: dockerInstallation.backendExecutablePath
        )
        assertDomainRule(
            rules[1],
            executablePath: dockerInstallation.backendExecutablePath,
            hostname: "gcr.io"
        )
        XCTAssertEqual(configuration.route.final, "direct")
    }

    func testContainerRegistriesUsesOnlyExactGCRHostname() throws {
        let configuration = try containerRegistriesOnlyConfiguration()
        let routedDomains = configuration.route.rules.flatMap { $0.domains ?? [] }
        let json = try XCTUnwrap(
            String(data: configuration.encodedJSON(), encoding: .utf8)
        )

        XCTAssertEqual(routedDomains, ["gcr.io"])
        for excluded in [
            "foo.gcr.io",
            "us.gcr.io",
            "eu.gcr.io",
            "asia.gcr.io",
            "storage.googleapis.com",
            "googleapis.com",
            "googleusercontent.com",
            "ghcr.io",
            "quay.io",
            "registry.k8s.io",
            "example.com",
        ] {
            XCTAssertFalse(routedDomains.contains(excluded))
        }
        XCTAssertFalse(json.contains("domain_suffix"))
        XCTAssertFalse(json.contains("domain_regex"))
        XCTAssertFalse(json.contains("*.gcr.io"))
        XCTAssertFalse(json.contains("override_destination"))
    }

    func testContainerRegistriesCombinationsShareOneBackendSniff() throws {
        let cases: [(SingBoxConfiguration, [String], Bool)] = [
            (
                try SingBoxConfigurationBuilder.make(
                    outline: outline,
                    chromeBundlePath: nil,
                    codexExecutablePath: nil,
                    vsCodePluginHelperExecutablePath: nil,
                    dockerHubInstallation: dockerInstallation,
                    containerRegistriesInstallation: dockerInstallation
                ),
                DockerHubRoutePolicy.backendHostnames
                    + ContainerRegistriesRoutePolicy.backendHostnames,
                true
            ),
            (
                try SingBoxConfigurationBuilder.make(
                    outline: outline,
                    chromeBundlePath: nil,
                    codexExecutablePath: nil,
                    vsCodePluginHelperExecutablePath: nil,
                    kubernetesInstallation: dockerInstallation,
                    containerRegistriesInstallation: dockerInstallation
                ),
                KubernetesRoutePolicy.backendHostnames
                    + ContainerRegistriesRoutePolicy.backendHostnames,
                false
            ),
            (
                try SingBoxConfigurationBuilder.make(
                    outline: outline,
                    chromeBundlePath: nil,
                    codexExecutablePath: nil,
                    vsCodePluginHelperExecutablePath: nil,
                    dockerHubInstallation: dockerInstallation,
                    kubernetesInstallation: dockerInstallation,
                    containerRegistriesInstallation: dockerInstallation
                ),
                DockerHubRoutePolicy.backendHostnames
                    + KubernetesRoutePolicy.backendHostnames
                    + ContainerRegistriesRoutePolicy.backendHostnames,
                true
            ),
        ]
        let backendPattern = try exactRegex(for: dockerInstallation.backendExecutablePath)
        let cliPattern = try exactRegex(for: dockerInstallation.cliExecutablePath)

        for (configuration, expectedDomains, expectsDockerCLI) in cases {
            let backendRules = configuration.route.rules.filter {
                $0.processPathRegex == [backendPattern]
            }
            let backendSniffs = backendRules.filter { $0.action == "sniff" }
            let routedDomains = backendRules.flatMap { $0.domains ?? [] }
            let hasDockerCLIRules = configuration.route.rules.contains {
                $0.processPathRegex == [cliPattern]
            }

            XCTAssertEqual(backendSniffs.count, 1)
            XCTAssertEqual(routedDomains, expectedDomains)
            XCTAssertEqual(Set(routedDomains).count, routedDomains.count)
            XCTAssertEqual(hasDockerCLIRules, expectsDockerCLI)
            XCTAssertEqual(configuration.route.final, "direct")
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

    func testSyntheticKubernetesCombinationsPassBundledSingBoxCheck() throws {
        let configurations = [
            try kubernetesOnlyConfiguration(),
            try dockerOnlyConfiguration(),
            try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: nil,
                codexExecutablePath: nil,
                vsCodePluginHelperExecutablePath: nil,
                dockerHubInstallation: dockerInstallation,
                kubernetesInstallation: dockerInstallation
            ),
            try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: nil,
                codexExecutablePath: nil,
                vsCodePluginHelperExecutablePath: nil,
                kubernetesInstallation: dockerInstallation,
                homebrewEnabled: true,
                homebrewGitInstallation: gitInstallation
            ),
            try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: nil,
                codexExecutablePath: nil,
                vsCodePluginHelperExecutablePath: nil,
                gitInstallation: gitInstallation,
                kubernetesInstallation: dockerInstallation
            ),
            try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: nil,
                codexExecutablePath: codexPath,
                vsCodePluginHelperExecutablePath: vsCodePluginHelperPath,
                kubernetesInstallation: dockerInstallation
            ),
            try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: chromePath,
                codexExecutablePath: nil,
                vsCodePluginHelperExecutablePath: nil,
                kubernetesInstallation: dockerInstallation,
                proxyWebsiteHostnames: ["chatgpt.com"]
            ),
        ]

        for (index, configuration) in configurations.enumerated() {
            try assertPassesBundledSingBoxCheck(
                configuration,
                name: "Kubernetes-\(index)"
            )
        }
    }

    func testSyntheticContainerRegistriesCombinationsPassBundledSingBoxCheck() throws {
        let configurations = [
            try containerRegistriesOnlyConfiguration(),
            try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: nil,
                codexExecutablePath: nil,
                vsCodePluginHelperExecutablePath: nil,
                dockerHubInstallation: dockerInstallation,
                containerRegistriesInstallation: dockerInstallation
            ),
            try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: nil,
                codexExecutablePath: nil,
                vsCodePluginHelperExecutablePath: nil,
                kubernetesInstallation: dockerInstallation,
                containerRegistriesInstallation: dockerInstallation
            ),
            try SingBoxConfigurationBuilder.make(
                outline: outline,
                chromeBundlePath: nil,
                codexExecutablePath: nil,
                vsCodePluginHelperExecutablePath: nil,
                dockerHubInstallation: dockerInstallation,
                kubernetesInstallation: dockerInstallation,
                containerRegistriesInstallation: dockerInstallation
            ),
        ]

        for (index, configuration) in configurations.enumerated() {
            try assertPassesBundledSingBoxCheck(
                configuration,
                name: "ContainerRegistries-\(index)"
            )
        }
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

    private func kubernetesOnlyConfiguration() throws -> SingBoxConfiguration {
        try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            kubernetesInstallation: dockerInstallation
        )
    }

    private func containerRegistriesOnlyConfiguration() throws -> SingBoxConfiguration {
        try SingBoxConfigurationBuilder.make(
            outline: outline,
            chromeBundlePath: nil,
            codexExecutablePath: nil,
            vsCodePluginHelperExecutablePath: nil,
            containerRegistriesInstallation: dockerInstallation
        )
    }

    private func assertPassesBundledSingBoxCheck(
        _ configuration: SingBoxConfiguration,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-\(name)-\(UUID().uuidString).json")
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
        XCTAssertEqual(process.terminationStatus, 0, message, file: file, line: line)
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
