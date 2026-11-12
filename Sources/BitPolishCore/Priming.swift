import Foundation

/// The layout of the Manually Prime DAC buttons: two rows by rate family, the
/// 44.1 kHz family over the 48 kHz family, each rate above or below its
/// counterpart (88.2 over 96, and so on). Columns run up to 192 kHz, or the
/// device's highest rate if that's higher, so a device that tops out lower
/// still shows the rates it can't take, in place.
public enum Priming {
    public struct Cell: Equatable, Sendable {
        public var rate: Double
        /// True if the device accepts this rate.
        public var supported: Bool
        /// The rate a track at this rate actually plays at on this device
        /// (itself when supported).
        public var playsAt: Double
        public init(rate: Double, supported: Bool, playsAt: Double) {
            self.rate = rate; self.supported = supported; self.playsAt = playsAt
        }
    }

    public static let families: [[Double]] = [
        [44_100, 88_200, 176_400, 352_800, 705_600],
        [48_000, 96_000, 192_000, 384_000, 768_000],
    ]
    public static let standardRates: [Double] = families.flatMap { $0 }.sorted()

    /// Two rows of cells for a device's offered rates; empty if it offers
    /// none of the standard rates.
    public static func rows(supported: [Double]) -> [[Cell]] {
        let offered = standardRates.filter { supported.contains($0) }
        guard let top = offered.last else { return [] }
        let limit = max(192_000, top)
        let columns = families.map { row in row.lastIndex { $0 <= limit } ?? 0 }.max()! + 1
        return families.map { row in
            row.prefix(columns).map { rate in
                Cell(rate: rate, supported: offered.contains(rate),
                     playsAt: TrackFormat.outputRate(for: rate, supported: offered, current: top))
            }
        }
    }
}
