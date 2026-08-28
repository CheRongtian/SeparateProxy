import Darwin
import Foundation
import XCTest
@testable import SeparateProxyCore

final class TrafficAccountingTests: XCTestCase {
    func testValidSnapshotParsing() throws {
        let reader = makeReader(data: try validSnapshotData())

        let snapshot = try reader.readSnapshot()

        XCTAssertEqual(snapshot.sessionIdentifier, "session-a")
        XCTAssertEqual(snapshot.proxyUploadBytes, 10)
        XCTAssertEqual(snapshot.proxyDownloadBytes, 20)
        XCTAssertEqual(snapshot.directUploadBytes, 30)
        XCTAssertEqual(snapshot.directDownloadBytes, 40)
    }

    func testUnsupportedVersionIsRejected() throws {
        let reader = makeReader(data: try snapshotData(version: 2))

        XCTAssertThrowsError(try reader.readSnapshot()) { error in
            XCTAssertEqual(error as? TrafficAccountingReaderError, .unsupportedVersion(2))
        }
    }

    func testOversizedResponseIsRejected() {
        let reader = makeReader(
            data: Data(repeating: 0x41, count: TrafficAccountingReader.maximumResponseBytes + 1)
        )

        XCTAssertThrowsError(try reader.readSnapshot()) { error in
            XCTAssertEqual(error as? TrafficAccountingReaderError, .responseTooLarge)
        }
    }

    func testMalformedJSONIsRejected() {
        let reader = makeReader(data: Data(#"{"version":1"#.utf8))

        XCTAssertThrowsError(try reader.readSnapshot()) { error in
            XCTAssertEqual(error as? TrafficAccountingReaderError, .malformedSnapshot)
        }
    }

    func testMissingSocketReportsUnavailableWithoutStartingAnything() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparateProxy-Traffic-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(Darwin.chmod(directory.path, 0o700), 0)
        let reader = TrafficAccountingReader(
            socketURL: directory.appendingPathComponent("traffic.sock"),
            expectedOwner: getuid()
        )

        XCTAssertThrowsError(try reader.readSnapshot()) { error in
            XCTAssertEqual(error as? TrafficAccountingReaderError, .unavailable)
        }
    }

    func testXPCSuccessReplyContainsOnlyExpectedFields() throws {
        let snapshot = try makeReader(data: validSnapshotData()).readSnapshot()

        let reply = TrafficAccountingReplyBuilder.success(snapshot)

        XCTAssertEqual(Set(reply.allKeys.compactMap { $0 as? String }), [
            TrafficAccountingReplyKey.success,
            TrafficAccountingReplyKey.message,
            TrafficAccountingReplyKey.sessionIdentifier,
            TrafficAccountingReplyKey.proxyUploadBytes,
            TrafficAccountingReplyKey.proxyDownloadBytes,
            TrafficAccountingReplyKey.directUploadBytes,
            TrafficAccountingReplyKey.directDownloadBytes,
        ])
        let serialized = String(describing: reply)
        XCTAssertFalse(serialized.contains("password"))
        XCTAssertFalse(serialized.contains("accessKey"))
        XCTAssertFalse(serialized.contains("config"))
        XCTAssertFalse(serialized.contains("log"))
    }

    func testFailureReplyContainsOnlyStatusAndMessage() {
        let reply = TrafficAccountingReplyBuilder.failure(
            TrafficAccountingReaderError.unavailable
        )

        XCTAssertEqual(Set(reply.allKeys.compactMap { $0 as? String }), [
            TrafficAccountingReplyKey.success,
            TrafficAccountingReplyKey.message,
        ])
    }

    func testNormalCounterDeltaCalculatesIndependentRates() {
        var calculator = TrafficRateCalculator()
        let clock = ContinuousClock()
        let start = clock.now
        let first = snapshot(
            session: "same",
            proxyUpload: 100,
            proxyDownload: 200,
            directUpload: 300,
            directDownload: 400
        )
        let second = snapshot(
            session: "same",
            proxyUpload: 300,
            proxyDownload: 600,
            directUpload: 900,
            directDownload: 1_200
        )

        XCTAssertEqual(calculator.update(first, at: start), .zero)
        let rates = calculator.update(second, at: start.advanced(by: .seconds(2)))

        XCTAssertEqual(rates.proxyUploadBytesPerSecond, 100, accuracy: 0.0001)
        XCTAssertEqual(rates.proxyDownloadBytesPerSecond, 200, accuracy: 0.0001)
        XCTAssertEqual(rates.directUploadBytesPerSecond, 300, accuracy: 0.0001)
        XCTAssertEqual(rates.directDownloadBytesPerSecond, 400, accuracy: 0.0001)
    }

    func testSessionChangeResetsRatesToZero() {
        var calculator = TrafficRateCalculator()
        let start = ContinuousClock().now
        _ = calculator.update(snapshot(session: "one", proxyUpload: 100), at: start)

        let rates = calculator.update(
            snapshot(session: "two", proxyUpload: 1_000),
            at: start.advanced(by: .seconds(1))
        )

        XCTAssertEqual(rates, .zero)
    }

    func testCounterDecreaseResetsAllRatesToZero() {
        var calculator = TrafficRateCalculator()
        let start = ContinuousClock().now
        _ = calculator.update(
            snapshot(
                session: "same",
                proxyUpload: 100,
                proxyDownload: 200,
                directUpload: 300,
                directDownload: 400
            ),
            at: start
        )

        let rates = calculator.update(
            snapshot(
                session: "same",
                proxyUpload: 99,
                proxyDownload: 300,
                directUpload: 400,
                directDownload: 500
            ),
            at: start.advanced(by: .seconds(1))
        )

        XCTAssertEqual(rates, .zero)
    }

    func testTrafficQueryReadsExactlyOneSnapshotAndHasNoLifecycleCommand() throws {
        var readCount = 0
        let reader = TrafficAccountingReader(
            socketURL: URL(fileURLWithPath: "/unused/traffic.sock"),
            expectedOwner: getuid()
        ) {
            readCount += 1
            return try self.validSnapshotData()
        }

        _ = try reader.readSnapshot()

        XCTAssertEqual(readCount, 1)
    }

    func testTrafficRateFormatterFormatsZero() {
        XCTAssertEqual(TrafficRateFormatter.string(from: 0), "0 B/s")
    }

    func testTrafficRateFormatterFormatsBytes() {
        XCTAssertEqual(TrafficRateFormatter.string(from: 512), "512 B/s")
    }

    func testTrafficRateFormatterFormatsKilobytes() {
        XCTAssertEqual(TrafficRateFormatter.string(from: 24 * 1_024), "24 KB/s")
    }

    func testTrafficRateFormatterFormatsMegabytesAndGigabytes() {
        XCTAssertEqual(
            TrafficRateFormatter.string(from: 1.8 * 1_024 * 1_024),
            "1.8 MB/s"
        )
        XCTAssertEqual(
            TrafficRateFormatter.string(from: 1.2 * 1_024 * 1_024 * 1_024),
            "1.2 GB/s"
        )
    }

    func testTrafficPresentationStartsWithUnavailableSession() {
        let presentation = TrafficPresentationModel()

        XCTAssertEqual(presentation.displayState, .sessionUnavailable)
    }

    func testTrafficPresentationReportsAccountingUnavailable() {
        var presentation = TrafficPresentationModel()
        XCTAssertTrue(presentation.beginPolling())

        presentation.markAccountingUnavailable()

        XCTAssertEqual(presentation.displayState, .accountingUnavailable)
    }

    func testTrafficPresentationResetDoesNotShowPreviousSessionSpeed() {
        var presentation = TrafficPresentationModel()
        let start = ContinuousClock().now
        XCTAssertTrue(presentation.beginPolling())
        presentation.update(snapshot(session: "first", proxyUpload: 100), at: start)
        presentation.update(
            snapshot(session: "first", proxyUpload: 200),
            at: start.advanced(by: .seconds(1))
        )
        XCTAssertEqual(
            presentation.displayState,
            .active(
                TrafficRates(
                    proxyUploadBytesPerSecond: 100,
                    proxyDownloadBytesPerSecond: 0,
                    directUploadBytesPerSecond: 0,
                    directDownloadBytesPerSecond: 0
                )
            )
        )

        presentation.stopPolling()
        XCTAssertTrue(presentation.beginPolling())
        presentation.update(
            snapshot(session: "second", proxyUpload: 5_000),
            at: start.advanced(by: .seconds(2))
        )

        XCTAssertEqual(presentation.displayState, .active(.zero))
    }

    func testTrafficPresentationDoesNotStartSecondPollingLifecycle() {
        var presentation = TrafficPresentationModel()

        XCTAssertTrue(presentation.beginPolling())
        XCTAssertFalse(presentation.beginPolling())
        presentation.stopPolling()
        XCTAssertTrue(presentation.beginPolling())
    }

    private func makeReader(data: Data) -> TrafficAccountingReader {
        TrafficAccountingReader(
            socketURL: URL(fileURLWithPath: "/unused/traffic.sock"),
            expectedOwner: getuid()
        ) {
            data
        }
    }

    private func validSnapshotData() throws -> Data {
        try snapshotData(version: TrafficAccountingConstants.snapshotVersion)
    }

    private func snapshotData(version: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": version,
            "session_identifier": "session-a",
            "proxy_upload_bytes": 10,
            "proxy_download_bytes": 20,
            "direct_upload_bytes": 30,
            "direct_download_bytes": 40,
        ])
    }

    private func snapshot(
        session: String,
        proxyUpload: UInt64 = 0,
        proxyDownload: UInt64 = 0,
        directUpload: UInt64 = 0,
        directDownload: UInt64 = 0
    ) -> TrafficCountersSnapshot {
        TrafficCountersSnapshot(
            sessionIdentifier: session,
            proxyUploadBytes: proxyUpload,
            proxyDownloadBytes: proxyDownload,
            directUploadBytes: directUpload,
            directDownloadBytes: directDownload
        )
    }
}
