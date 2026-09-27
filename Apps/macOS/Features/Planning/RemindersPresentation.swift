import AppCore
import Foundation

/// What the main window shows of the reminders sheet when the reminders of the day are counted:
/// the daily reminders once a day, and — at every launch, once — the due dates passed and
/// unpaid, which are money the free sum counts as not yet gone until the owner says what
/// happened to them. The words of the decision, apart from the window, so a test can hold it.
struct RemindersPresentation: Equatable {
  /// The daily reminders the sheet lists; empty when only the overdue section is asked.
  var daily: [Reminder]
  /// The sheet opens with «Просроченные платежи» on top.
  var asksOverdue: Bool

  /// The sheet to show, or `nil` for none.
  ///
  /// * `daily` are shown when there are any and they were not shown today (`shownToday`);
  /// * `overdue` are asked about when there are any and they were not asked this launch
  ///   (`askedThisLaunch`), whatever the daily ones did — a reminder put off hides no overdue
  ///   due date;
  /// * `suppressed` — the launch said «no reminders» — shows nothing at all.
  static func decide(
    daily: [Reminder], overdue: [OverdueDue], shownToday: Bool, askedThisLaunch: Bool,
    suppressed: Bool = false
  ) -> RemindersPresentation? {
    guard !suppressed else { return nil }
    let showsDaily = !daily.isEmpty && !shownToday
    let asks = !overdue.isEmpty && !askedThisLaunch
    guard showsDaily || asks else { return nil }
    return RemindersPresentation(daily: showsDaily ? daily : [], asksOverdue: asks)
  }

  /// Whether the day's reminders are marked shown by this sheet.
  var marksDailyShown: Bool { !daily.isEmpty }
}
