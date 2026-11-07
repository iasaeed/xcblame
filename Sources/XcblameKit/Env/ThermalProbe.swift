import Foundation

/// `pmset -g therm` before and after a wrapped build (DESIGN §5.9). Optional: nil whenever the probe fails.
public enum ThermalProbe {
    /// Trimmed `pmset -g therm` output, nil when the probe fails or times out (2 s).
    public static func capture(probe: ([String]) -> String? = { runProbe($0, timeout: 2) }) -> String? {
        probe(["pmset", "-g", "therm"])
    }

    /// The `CPU_Speed_Limit` percentage in a `pmset -g therm` text; nil when pmset records none (the usual case).
    public static func cpuSpeedLimit(in text: String) -> Int? {
        for line in text.split(separator: "\n") where line.contains("CPU_Speed_Limit") {
            if let value = line.split(separator: "=").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                return value
            }
        }
        return nil
    }

    /// A note when either reading shows throttling (a speed limit below 100), else nil.
    public static func note(before: String?, after: String?) -> String? {
        let limits = [before, after].compactMap { $0.flatMap(cpuSpeedLimit) }
        guard let lowest = limits.min(), lowest < 100 else { return nil }
        return "thermal: CPU_Speed_Limit \(lowest)% during this build (pmset -g therm); timings may be inflated"
    }
}
