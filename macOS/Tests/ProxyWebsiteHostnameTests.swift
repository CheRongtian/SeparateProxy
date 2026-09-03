import Foundation
import XCTest
@testable import SeparateProxyCore

final class ProxyWebsiteHostnameTests: XCTestCase {
    func testNormalizesHTTPSURLToExactHostname() throws {
        XCTAssertEqual(
            try ProxyWebsiteHostnameNormalizer.normalize(
                "  https://WWW.Example.COM/path?q=1#fragment  "
            ),
            "www.example.com"
        )
        XCTAssertEqual(
            try ProxyWebsiteHostnameNormalizer.normalize("HTTPS://CHATGPT.COM/"),
            "chatgpt.com"
        )
    }

    func testAcceptsBareHostnameAndRemovesOneTrailingDot() throws {
        XCTAssertEqual(
            try ProxyWebsiteHostnameNormalizer.normalize("Example.COM."),
            "example.com"
        )
    }

    func testConvertsUnicodeHostnameToASCII() throws {
        XCTAssertEqual(
            try ProxyWebsiteHostnameNormalizer.normalize("https://bücher.de/"),
            "xn--bcher-kva.de"
        )
    }

    func testAllowsExplicitHTTPSPortOnly() throws {
        XCTAssertEqual(
            try ProxyWebsiteHostnameNormalizer.normalize("https://example.com:443/path"),
            "example.com"
        )
        XCTAssertThrowsError(
            try ProxyWebsiteHostnameNormalizer.normalize("https://example.com:8443")
        )
    }

    func testRejectsUnsupportedOrAmbiguousInputs() {
        let rejected = [
            "http://example.com",
            "ftp://example.com",
            "https://user:password@example.com",
            "https://*.example.com",
            "https://example..com",
            "example.com..",
            "example .com",
            "https://192.0.2.1",
            "https://[2001:db8::1]",
            "https://example.com:",
            #"example.com\",\"action\":\"route"#,
            "file:///tmp/example.com",
            "javascript:example.com",
        ]
        for input in rejected {
            XCTAssertThrowsError(
                try ProxyWebsiteHostnameNormalizer.normalize(input),
                "Expected rejection for \(input)"
            )
        }
    }

    func testAddingDeduplicatesAndSorts() throws {
        var hostnames = try ProxyWebsiteHostnameNormalizer.adding(
            "https://B.example/path",
            to: ["c.example", "a.example"]
        )
        hostnames = try ProxyWebsiteHostnameNormalizer.adding(
            "b.example",
            to: hostnames
        )
        XCTAssertEqual(hostnames, ["a.example", "b.example", "c.example"])
    }

    func testCustomValidationRequiresCanonicalNormalizedList() throws {
        XCTAssertEqual(
            try ProxyWebsiteHostnameNormalizer.validateCustomNormalizedList([
                "example.com",
                "chatgpt.com",
                "example.com",
            ]),
            ["chatgpt.com", "example.com"]
        )
        for invalid in [
            ["Example.com"],
            ["https://example.com"],
            ["example.com/"],
            ["*.example.com"],
            ["192.0.2.1"],
        ] {
            XCTAssertThrowsError(
                try ProxyWebsiteHostnameNormalizer.validateCustomNormalizedList(invalid)
            )
        }
    }

    func testCustomListRejectsMoreThanOneHundredHostnames() {
        let hostnames = (0...100).map { "host\($0).example" }
        XCTAssertThrowsError(
            try ProxyWebsiteHostnameNormalizer.validateCustomNormalizedList(hostnames)
        ) { error in
            XCTAssertEqual(
                error as? ProxyWebsiteHostnameError,
                .tooManyCustomHostnames
            )
        }
    }

    func testExactHostnameDoesNotImplySubdomains() throws {
        let hostnames = try ProxyWebsiteHostnameNormalizer.validateCustomNormalizedList([
            "chatgpt.com",
        ])
        XCTAssertTrue(hostnames.contains("chatgpt.com"))
        XCTAssertFalse(hostnames.contains("ab.chatgpt.com"))
        XCTAssertFalse(hostnames.contains("evilchatgpt.com"))

        XCTAssertEqual(
            try ProxyWebsiteHostnameNormalizer.adding(
                "https://ab.chatgpt.com/path",
                to: hostnames
            ),
            ["ab.chatgpt.com", "chatgpt.com"]
        )
    }

    func testGoogleWebsiteRoutingContainsExactlyTheFrozenElevenExactHostnames() throws {
        XCTAssertEqual(GoogleWebsiteRouting.hostnames.count, 11)
        XCTAssertEqual(Set(GoogleWebsiteRouting.hostnames), Set([
            "google.com",
            "www.google.com",
            "drive.google.com",
            "docs.google.com",
            "sheets.google.com",
            "slides.google.com",
            "drive.usercontent.google.com",
            "accounts.google.com",
            "gemini.google.com",
            "jnn-pa.googleapis.com",
            "www.googleapis.com",
        ]))
        XCTAssertEqual(
            try ProxyWebsiteHostnameNormalizer.validateEffectiveNormalizedList(
                GoogleWebsiteRouting.hostnames
            ),
            GoogleWebsiteRouting.hostnames.sorted()
        )
        XCTAssertTrue(GoogleWebsiteRouting.hostnames.allSatisfy { hostname in
            !hostname.contains("*") && !hostname.hasPrefix(".")
        })
    }

    func testGoogleWebsiteRoutingDisabledPreservesExistingCustomBehavior() throws {
        XCTAssertEqual(
            try GoogleWebsiteRouting.effectiveHostnames(
                customHostnames: [],
                isEnabled: false
            ),
            []
        )
        XCTAssertEqual(
            try GoogleWebsiteRouting.effectiveHostnames(
                customHostnames: ["z.example.com", "a.example.com"],
                isEnabled: false
            ),
            ["a.example.com", "z.example.com"]
        )
        XCTAssertEqual(
            try GoogleWebsiteRouting.effectiveHostnames(
                customHostnames: [],
                isEnabled: true
            ),
            GoogleWebsiteRouting.hostnames.sorted()
        )
    }

    func testGoogleWebsiteRoutingMergesDeduplicatesAndDoesNotMutateCustomData() throws {
        let customHostnames = ["z.example.com", "accounts.google.com"]
        let originalCustomHostnames = customHostnames
        let effective = try GoogleWebsiteRouting.effectiveHostnames(
            customHostnames: customHostnames,
            isEnabled: true
        )

        XCTAssertEqual(customHostnames, originalCustomHostnames)
        XCTAssertEqual(effective, Array(Set(
            customHostnames + GoogleWebsiteRouting.hostnames
        )).sorted())
        XCTAssertEqual(effective.filter { $0 == "accounts.google.com" }.count, 1)
    }

    func testGoogleWebsiteRoutingAcceptsOneHundredCustomPlusElevenBuiltIn() throws {
        let customHostnames = (0..<100).map { "host\($0).example" }
        let effective = try GoogleWebsiteRouting.effectiveHostnames(
            customHostnames: customHostnames,
            isEnabled: true
        )

        XCTAssertEqual(effective.count, 111)
        XCTAssertEqual(
            try ProxyWebsiteHostnameNormalizer.validateEffectiveNormalizedList(effective),
            effective
        )

        let tooManyCustomHostnames = (0..<101).map { "custom\($0).example" }
        XCTAssertThrowsError(
            try GoogleWebsiteRouting.effectiveHostnames(
                customHostnames: tooManyCustomHostnames,
                isEnabled: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ProxyWebsiteHostnameError,
                .tooManyCustomHostnames
            )
        }
    }

    func testEffectiveListAcceptsOneHundredElevenAndRejectsOneHundredTwelve() throws {
        let accepted = (0..<111).map { "host\($0).example" }
        XCTAssertEqual(
            try ProxyWebsiteHostnameNormalizer.validateEffectiveNormalizedList(accepted),
            accepted.sorted()
        )

        let rejected = (0..<112).map { "host\($0).example" }
        XCTAssertThrowsError(
            try ProxyWebsiteHostnameNormalizer.validateEffectiveNormalizedList(rejected)
        ) { error in
            XCTAssertEqual(
                error as? ProxyWebsiteHostnameError,
                .tooManyEffectiveHostnames
            )
        }
        XCTAssertThrowsError(
            try ProxyWebsiteHostnameNormalizer.validateEffectiveNormalizedList([
                "*.example.com",
            ])
        )
    }

    func testHostnameVisibilityRequirementCoversGoogleAndCustomCombinations() {
        XCTAssertFalse(GoogleWebsiteRouting.requiresHostnameVisibility(
            chromeIsSelected: true,
            customHostnames: [],
            isEnabled: false
        ))
        XCTAssertTrue(GoogleWebsiteRouting.requiresHostnameVisibility(
            chromeIsSelected: true,
            customHostnames: ["example.com"],
            isEnabled: false
        ))
        XCTAssertTrue(GoogleWebsiteRouting.requiresHostnameVisibility(
            chromeIsSelected: true,
            customHostnames: [],
            isEnabled: true
        ))
        XCTAssertTrue(GoogleWebsiteRouting.requiresHostnameVisibility(
            chromeIsSelected: true,
            customHostnames: ["example.com"],
            isEnabled: true
        ))
        XCTAssertFalse(GoogleWebsiteRouting.requiresHostnameVisibility(
            chromeIsSelected: false,
            customHostnames: ["example.com"],
            isEnabled: true
        ))
    }
}
