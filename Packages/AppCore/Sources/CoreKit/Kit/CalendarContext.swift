import Foundation

/// Resolves days and months in an explicit time zone. The app passes the system zone,
/// tests pass a fixed one, and the rates module passes `Europe/Moscow` where the Bank of
/// Russia publishes its daily rates.
public struct CalendarContext: Sendable {
  public let timeZone: TimeZone
  private let calendar: Calendar

  public init(timeZone: TimeZone) {
    self.timeZone = timeZone
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.firstWeekday = 2  // Monday, matching the Russian week used in reports
    self.calendar = calendar
  }

  public static let moscow = CalendarContext(
    timeZone: TimeZone(identifier: "Europe/Moscow") ?? TimeZone(secondsFromGMT: 3 * 3600)!)

  public static let utc = CalendarContext(timeZone: TimeZone(secondsFromGMT: 0)!)

  public static var system: CalendarContext { CalendarContext(timeZone: .current) }

  public func day(of instant: Date) -> DateOnly {
    let parts = calendar.dateComponents([.year, .month, .day], from: instant)
    return DateOnly(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
  }

  public func startOfDay(_ day: DateOnly) -> Date {
    var parts = DateComponents()
    parts.year = day.year
    parts.month = day.month
    parts.day = day.day
    parts.timeZone = timeZone
    return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
  }

  /// The moment an operation dated `day` gets when nobody said at what time: the start of
  /// the day plus twelve hours, far from both midnights. The entry line gives it to a day
  /// typed without a time, «Mark as paid» to a past due, the debt forms to a payment of
  /// another day; the duplicate rule of the anomalies reads it as «no time of its own».
  public func noon(of day: DateOnly) -> Date {
    startOfDay(day).addingTimeInterval(12 * 3600)
  }

  /// The last moment of the day: a millisecond before the next day starts. A day is not always
  /// twenty-four hours long — the clocks move — so it ends where the next begins, not a fixed
  /// time after its own start: on a day of 23 hours that would be the next day, on one of 25
  /// an hour short.
  public func endOfDay(_ day: DateOnly) -> Date {
    startOfDay(adding(days: 1, to: day)).addingTimeInterval(-0.001)
  }

  public func adding(days: Int, to origin: DateOnly) -> DateOnly {
    let shifted = calendar.date(byAdding: .day, value: days, to: startOfDay(origin))
    return day(of: shifted ?? startOfDay(origin))
  }

  /// Number of days in a month, used by budgets, pacing and forecasts.
  public func daysInMonth(_ month: MonthKey) -> Int {
    let start = startOfDay(month.firstDay)
    return calendar.range(of: .day, in: .month, for: start)?.count ?? 30
  }

  /// 1 = Monday … 7 = Sunday, so weekday statistics do not depend on the locale.
  public func weekdayIndex(_ day: DateOnly) -> Int {
    let weekday = calendar.component(.weekday, from: startOfDay(day))
    return ((weekday + 5) % 7) + 1
  }
}

/// Injectable clock so forecasts, reminders and tests never read the wall clock directly.
public protocol Clock: Sendable {
  var now: Date { get }
}

public struct SystemClock: Clock {
  public init() {}
  public var now: Date { Date() }
}

public struct FixedClock: Clock {
  public let now: Date
  public init(_ now: Date) { self.now = now }
}
