import Foundation

/// Integrity checks after xcodebuild exits (DESIGN §5.2): the log file must stop growing and, when a verifier is
/// supplied, its gzip trailer must check out.
public enum LogIntegrity {
    public enum Outcome: Sendable, Equatable {
        /// Size stable for the window and `verify` passed (or none was given).
        case stable(size: Int)
        /// Size stable but `verify` still failed at the timeout: parse what inflates, mark `degraded: truncated`.
        case unverified(size: Int)
        /// The file kept changing until the timeout.
        case stillGrowing
        case missing
    }

    /// Polls `url` until its size has been unchanged for `stableFor` seconds (500 ms by default) and `verify`
    /// (lane A passes `GzipFile.verifyTrailer`; the default accepts) is true, for up to `timeout` seconds.
    public static func waitForStable(_ url: URL, timeout: TimeInterval = 20, stableFor: TimeInterval = 0.5,
                                     pollInterval: TimeInterval = 0.1,
                                     verify: (URL) -> Bool = { _ in true }) -> Outcome {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)
        var lastSize: Int?
        var stableSince = clock.now
        var stableButUnverified: Int?
        while true {
            guard let size = fileSize(url) else { return .missing }
            if size != lastSize {
                lastSize = size
                stableSince = clock.now
                stableButUnverified = nil
            } else if clock.now - stableSince >= .seconds(stableFor) {
                if verify(url) { return .stable(size: size) }
                stableButUnverified = size
            }
            if clock.now >= deadline { return stableButUnverified.map { .unverified(size: $0) } ?? .stillGrowing }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }
}
