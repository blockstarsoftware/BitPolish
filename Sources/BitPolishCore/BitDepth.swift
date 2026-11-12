import Foundation

/// Which bit depth to hold the output at. 24-bit by default: it carries 16-
/// and 24-bit music unchanged, and S/PDIF (optical, coax) carries no more.
/// A device that offers more gets its maximum as the other choice; nothing
/// below 24 is offered, since 16-bit would cut 24-bit tracks short.
public enum BitDepth {
    public static let standard = 24

    /// The choices for a device whose deepest integer format is `deviceMax`
    /// bits: [24, max] when it goes higher, otherwise just its maximum.
    public static func choices(deviceMax: Int) -> [Int] {
        guard deviceMax > 0 else { return [] }
        return deviceMax > standard ? [standard, deviceMax] : [deviceMax]
    }

    /// The bit depth to use: the stored choice if it's still offered,
    /// otherwise 24 (or the device's maximum, if that's lower).
    public static func resolve(stored: Int?, deviceMax: Int) -> Int {
        if let stored, choices(deviceMax: deviceMax).contains(stored) { return stored }
        return min(standard, deviceMax)
    }

    /// Bit-depth labels that share one list of rates, joined for the Details
    /// panel: ["24-bit", "32-bit"] reads "24- and 32-bit"; a label with more
    /// than "N-bit" in it (like "32-bit float") is kept whole.
    public static func joinedLabel(_ labels: [String]) -> String {
        guard labels.count > 1 else { return labels.first ?? "" }
        let plain = labels.allSatisfy { $0.hasSuffix("-bit") && Int($0.dropLast(4)) != nil }
        let parts = plain ? labels.dropLast().map { String($0.dropLast(3)) } + [labels.last!] : labels
        return parts.count == 2 ? "\(parts[0]) and \(parts[1])"
                                : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
}
