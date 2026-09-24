import Foundation
import Testing

@testable import CoreKit

@Suite("Days and months are resolved in an explicit time zone")
struct CalendarTests {
  @Test func isoRoundTrip() {
    let day = DateOnly(iso: "2026-09-17")
    #expect(day == DateOnly(year: 2026, month: 9, day: 17))
    #expect(day?.iso == "2026-09-17")
    #expect(DateOnly(iso: "2026-13-01") == nil)
  }

  @Test func monthsWrapAroundTheYear() {
    let december = MonthKey(year: 2026, month: 12)
    #expect(december.next == MonthKey(year: 2027, month: 1))
    #expect(MonthKey(year: 2026, month: 1).previous == MonthKey(year: 2025, month: 12))
    #expect(december.firstDay == DateOnly(year: 2026, month: 12, day: 1))
  }

  @Test func daysInMonthFollowTheCalendar() {
    let context = CalendarContext.utc
    #expect(context.daysInMonth(MonthKey(year: 2026, month: 2)) == 28)
    #expect(context.daysInMonth(MonthKey(year: 2028, month: 2)) == 29)
    #expect(context.daysInMonth(MonthKey(year: 2026, month: 9)) == 30)
  }

  @Test func weekdayIndexStartsOnMonday() {
    let context = CalendarContext.utc
    #expect(context.weekdayIndex(DateOnly(year: 2026, month: 9, day: 14)) == 1)  // Monday
    #expect(context.weekdayIndex(DateOnly(year: 2026, month: 9, day: 20)) == 7)  // Sunday
  }

  @Test func dayBoundaryFollowsTheGivenZone() {
    let moscow = CalendarContext.moscow
    let utc = CalendarContext.utc
    // 2026-09-17 22:30 UTC is already the 18th in Moscow.
    let instant = utc.startOfDay(DateOnly(year: 2026, month: 9, day: 17))
      .addingTimeInterval(22 * 3600 + 1800)
    #expect(utc.day(of: instant) == DateOnly(year: 2026, month: 9, day: 17))
    #expect(moscow.day(of: instant) == DateOnly(year: 2026, month: 9, day: 18))
  }
}
