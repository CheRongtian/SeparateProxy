import Foundation
import SeparateProxyCore

enum TrafficDisplayState: Equatable {
    case sessionUnavailable
    case active(TrafficRates)
    case accountingUnavailable
}

struct TrafficPresentationModel {
    private(set) var displayState: TrafficDisplayState = .sessionUnavailable
    private(set) var isPolling = false
    private var rateCalculator = TrafficRateCalculator()

    mutating func beginPolling() -> Bool {
        guard !isPolling else {
            return false
        }
        isPolling = true
        rateCalculator.reset()
        displayState = .active(.zero)
        return true
    }

    mutating func stopPolling() {
        isPolling = false
        rateCalculator.reset()
        displayState = .sessionUnavailable
    }

    mutating func update(
        _ snapshot: TrafficCountersSnapshot,
        at instant: ContinuousClock.Instant = ContinuousClock().now
    ) {
        guard isPolling else {
            return
        }
        displayState = .active(rateCalculator.update(snapshot, at: instant))
    }

    mutating func markAccountingUnavailable() {
        guard isPolling else {
            return
        }
        rateCalculator.reset()
        displayState = .accountingUnavailable
    }
}

enum TrafficRateFormatter {
    private static let units = ["B/s", "KB/s", "MB/s", "GB/s"]

    static func string(from bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else {
            return "0 B/s"
        }

        var value = bytesPerSecond
        var unitIndex = 0
        while value >= 1_024, unitIndex < units.count - 1 {
            value /= 1_024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(Int(value.rounded())) \(units[unitIndex])"
        }
        let number = value >= 10
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
        return "\(number) \(units[unitIndex])"
    }
}
