import Foundation

public enum Format {
    /// 44100 -> "44.1", 48000 -> "48", 176400 -> "176.4". No trailing ".0".
    public static func rate(_ hz: Double) -> String {
        let khz = hz / 1000
        if khz == khz.rounded() { return String(Int(khz)) }
        return String(format: "%.1f", khz)
    }
}
