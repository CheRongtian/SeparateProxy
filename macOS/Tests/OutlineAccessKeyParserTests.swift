import Foundation
import XCTest
@testable import SeparateProxyCore

final class OutlineAccessKeyParserTests: XCTestCase {
    private let fakeMethod = "aes-256-gcm"
    private let fakePassword = "test-only-password"
    private let fakeServer = "192.0.2.1"
    private let fakePort: UInt16 = 8388

    func testParsesSIP002KeyWithoutNetworkAccess() throws {
        let credentials = Data("\(fakeMethod):\(fakePassword)".utf8)
            .base64EncodedString()
        let key = "ss://\(credentials)@\(fakeServer):\(fakePort)#Synthetic%20Test"

        let parsed = try OutlineAccessKeyParser.parse(key)

        XCTAssertEqual(parsed.server, fakeServer)
        XCTAssertEqual(parsed.serverPort, fakePort)
        XCTAssertEqual(parsed.method, fakeMethod)
        XCTAssertEqual(parsed.password, fakePassword)
    }

    func testParsesLegacyBase64KeyWithoutNetworkAccess() throws {
        let payload = "\(fakeMethod):\(fakePassword)@\(fakeServer):\(fakePort)"
        let key = "ss://\(Data(payload.utf8).base64EncodedString())"

        let parsed = try OutlineAccessKeyParser.parse(key)

        XCTAssertEqual(parsed.server, fakeServer)
        XCTAssertEqual(parsed.serverPort, fakePort)
        XCTAssertEqual(parsed.method, fakeMethod)
        XCTAssertEqual(parsed.password, fakePassword)
    }

    func testRejectsInvalidSyntheticKey() {
        XCTAssertThrowsError(
            try OutlineAccessKeyParser.parse("ss://TEST_ONLY_INVALID_PLACEHOLDER")
        )
    }

    func testRejectsNonShadowsocksScheme() {
        XCTAssertThrowsError(
            try OutlineAccessKeyParser.parse("https://example.invalid")
        ) { error in
            XCTAssertEqual(error as? OutlineAccessKeyError, .invalidScheme)
        }
    }
}
