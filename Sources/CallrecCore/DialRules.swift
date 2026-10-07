import Foundation

/// The dialer's guardrail numbers, parsed and sanitised from `Config`.
/// A bad config value falls back to the spec default and says so in the log:
/// a typo must never silently widen a guardrail.
public struct DialRules: Equatable, Sendable {
    public var dailyCap = 30
    public var hourlyCap = 10
    public var gapMin: TimeInterval = 45
    public var gapMax: TimeInterval = 120
    /// Seconds after local midnight; end is exclusive.
    public var hoursStart: Int = 10 * 3600
    public var hoursEnd: Int = 18 * 3600 + 30 * 60
    /// ISO weekdays, 1 = Monday ... 7 = Sunday.
    public var days: Set<Int> = [1, 2, 3, 4, 5, 6]
    public var cooldownDays = 7
    public var dncPausePerDay = 3
    public var failurePauseCount = 3
    public var shortCallSeconds = 5
    public var notPlacedTimeout: TimeInterval = 45

    public init() {}

    public init(config: Config) {
        let d = DialRules()
        dailyCap = max(config.dailyCap, 0)
        hourlyCap = max(config.hourlyCap, 0)
        if config.gapSeconds.count == 2, config.gapSeconds[0] >= 0, config.gapSeconds[0] <= config.gapSeconds[1] {
            gapMin = TimeInterval(config.gapSeconds[0]); gapMax = TimeInterval(config.gapSeconds[1])
        } else {
            log("dialer: gapSeconds \(config.gapSeconds) is not [min, max]; using 45-120")
            gapMin = d.gapMin; gapMax = d.gapMax
        }
        if config.callingHours.count == 2, let s = Self.secondsOfDay(config.callingHours[0]),
           let e = Self.secondsOfDay(config.callingHours[1]), s < e {
            hoursStart = s; hoursEnd = e
        } else {
            log("dialer: callingHours \(config.callingHours) is not [\"HH:mm\", \"HH:mm\"] with start before end; using 10:00-18:30")
            hoursStart = d.hoursStart; hoursEnd = d.hoursEnd
        }
        let valid = Set(config.callingDays).filter { (1...7).contains($0) }
        if valid.isEmpty {
            log("dialer: callingDays \(config.callingDays) has no weekday 1-7; using Monday-Saturday")
            days = d.days
        } else {
            days = valid
        }
        cooldownDays = max(config.cooldownDays, 0)
        dncPausePerDay = max(config.dncPausePerDay, 1)
        failurePauseCount = max(config.failurePauseCount, 1)
        shortCallSeconds = max(config.shortCallSeconds, 0)
        notPlacedTimeout = TimeInterval(max(config.notPlacedTimeoutSeconds, 1))
    }

    /// "10:00" or "18:30" -> seconds after midnight. nil if malformed.
    public static func secondsOfDay(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 3600 + m * 60
    }

    /// A random gap in [gapMin, gapMax] seconds, uniform.
    public func randomGap<G: RandomNumberGenerator>(using generator: inout G) -> TimeInterval {
        gapMin >= gapMax ? gapMin : TimeInterval.random(in: gapMin...gapMax, using: &generator)
    }
}

extension Config {
    public var dialRules: DialRules { DialRules(config: self) }
}
