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

    func testHelperValidationRequiresCanonicalNormalizedList() throws {
        XCTAssertEqual(
            try ProxyWebsiteHostnameNormalizer.validateNormalizedList([
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
                try ProxyWebsiteHostnameNormalizer.validateNormalizedList(invalid)
            )
        }
    }

    func testRejectsMoreThanOneHundredHostnames() {
        let hostnames = (0...100).map { "host\($0).example" }
        XCTAssertThrowsError(
            try ProxyWebsiteHostnameNormalizer.validateNormalizedList(hostnames)
        )
    }

    func testExactHostnameDoesNotImplySubdomains() throws {
        let hostnames = try ProxyWebsiteHostnameNormalizer.validateNormalizedList([
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
}
