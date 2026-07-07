import Foundation

/// Persists the monthly count of AI plan invocations so the free-tier quota
/// is enforced across app launches. We store the count alongside the start
/// of the calendar month so we can detect a rollover on next read.
///
/// Buckets: `n` is the count of AI-Plan runs invoked by the current
/// installation this calendar month.
enum AIUsagePeriodStore {
    private static let countKey = "rc.aiPlanUsage.count"
    private static let periodStartKey = "rc.aiPlanUsage.periodStart"
    private static let defaults: UserDefaults = .standard

    static func startOfCurrentMonth(referenceDate: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = calendar.dateComponents(
            [.year, .month],
            from: referenceDate
        )
        return calendar.date(from: components) ?? referenceDate
    }

    static func read() -> (count: Int, periodStart: Date) {
        let storedStart = defaults.object(forKey: periodStartKey) as? Date ?? .distantPast
        let sameMonth = Calendar.current.compare(
            storedStart,
            to: startOfCurrentMonth(),
            toGranularity: .month
        ) == .orderedSame
        if !sameMonth {
            return (count: 0, periodStart: startOfCurrentMonth())
        }
        let count = defaults.integer(forKey: countKey)
        return (count: count, periodStart: storedStart)
    }

    static func write(count: Int, periodStart: Date) {
        defaults.set(count, forKey: countKey)
        defaults.set(periodStart, forKey: periodStartKey)
    }

    static func reset() {
        defaults.removeObject(forKey: countKey)
        defaults.removeObject(forKey: periodStartKey)
    }
}
