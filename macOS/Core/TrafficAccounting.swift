import Foundation

public enum TrafficAccountingConstants {
    public static let snapshotVersion = 1
    public static let socketPath = "/Library/Application Support/SeparateProxy/runtime/traffic.sock"
    public static let pollingInterval: Duration = .seconds(1)
}

public struct TrafficCountersSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionIdentifier: String
    public let proxyUploadBytes: UInt64
    public let proxyDownloadBytes: UInt64
    public let directUploadBytes: UInt64
    public let directDownloadBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case version
        case sessionIdentifier = "session_identifier"
        case proxyUploadBytes = "proxy_upload_bytes"
        case proxyDownloadBytes = "proxy_download_bytes"
        case directUploadBytes = "direct_upload_bytes"
        case directDownloadBytes = "direct_download_bytes"
    }

    public init(
        version: Int = TrafficAccountingConstants.snapshotVersion,
        sessionIdentifier: String,
        proxyUploadBytes: UInt64,
        proxyDownloadBytes: UInt64,
        directUploadBytes: UInt64,
        directDownloadBytes: UInt64
    ) {
        self.version = version
        self.sessionIdentifier = sessionIdentifier
        self.proxyUploadBytes = proxyUploadBytes
        self.proxyDownloadBytes = proxyDownloadBytes
        self.directUploadBytes = directUploadBytes
        self.directDownloadBytes = directDownloadBytes
    }
}

public struct TrafficRates: Equatable, Sendable {
    public let proxyUploadBytesPerSecond: Double
    public let proxyDownloadBytesPerSecond: Double
    public let directUploadBytesPerSecond: Double
    public let directDownloadBytesPerSecond: Double

    public static let zero = TrafficRates(
        proxyUploadBytesPerSecond: 0,
        proxyDownloadBytesPerSecond: 0,
        directUploadBytesPerSecond: 0,
        directDownloadBytesPerSecond: 0
    )
}

public struct TrafficRateCalculator: Sendable {
    private var previousSnapshot: TrafficCountersSnapshot?
    private var previousInstant: ContinuousClock.Instant?

    public init() {}

    public mutating func update(
        _ snapshot: TrafficCountersSnapshot,
        at instant: ContinuousClock.Instant = ContinuousClock().now
    ) -> TrafficRates {
        defer {
            previousSnapshot = snapshot
            previousInstant = instant
        }
        guard snapshot.version == TrafficAccountingConstants.snapshotVersion,
              !snapshot.sessionIdentifier.isEmpty,
              let previousSnapshot,
              let previousInstant,
              previousSnapshot.sessionIdentifier == snapshot.sessionIdentifier,
              countersDidNotDecrease(from: previousSnapshot, to: snapshot) else {
            return .zero
        }

        let elapsed = previousInstant.duration(to: instant)
        let components = elapsed.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds > 0 else {
            return .zero
        }
        return TrafficRates(
            proxyUploadBytesPerSecond: Double(
                snapshot.proxyUploadBytes - previousSnapshot.proxyUploadBytes
            ) / seconds,
            proxyDownloadBytesPerSecond: Double(
                snapshot.proxyDownloadBytes - previousSnapshot.proxyDownloadBytes
            ) / seconds,
            directUploadBytesPerSecond: Double(
                snapshot.directUploadBytes - previousSnapshot.directUploadBytes
            ) / seconds,
            directDownloadBytesPerSecond: Double(
                snapshot.directDownloadBytes - previousSnapshot.directDownloadBytes
            ) / seconds
        )
    }

    public mutating func reset() {
        previousSnapshot = nil
        previousInstant = nil
    }

    private func countersDidNotDecrease(
        from previous: TrafficCountersSnapshot,
        to current: TrafficCountersSnapshot
    ) -> Bool {
        current.proxyUploadBytes >= previous.proxyUploadBytes
            && current.proxyDownloadBytes >= previous.proxyDownloadBytes
            && current.directUploadBytes >= previous.directUploadBytes
            && current.directDownloadBytes >= previous.directDownloadBytes
    }
}
