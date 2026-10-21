import Foundation

/// Messages shows a timestamp above the first message in a thread and above any message that comes
/// more than an hour after the one before it.
let threadSeparatorGap: TimeInterval = 60 * 60

func needsThreadSeparator(at date: Date, after previous: Date?) -> Bool {
  guard let previous else { return true }
  return date.timeIntervalSince(previous) > threadSeparatorGap
}

/// A thread separator label, like Messages: "Today 12:06 PM", "Yesterday 9:41 AM",
/// "Thursday 12:04 PM" within the last week, and "Tue, Sep 8 at 4:43 PM" before that, with the
/// year when it isn't the current one. `day` is shown emphasized.
struct ThreadTimestamp: Equatable {
  var day: String
  var time: String

  init(day: String, time: String) {
    self.day = day
    self.time = time
  }

  init(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) {
    var calendar = calendar
    calendar.locale = locale
    let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    let time = date.formatted(base.hour().minute())
    let startOfToday = calendar.startOfDay(for: now)
    let startOfDay = calendar.startOfDay(for: date)
    let daysAgo = calendar.dateComponents([.day], from: startOfDay, to: startOfToday).day ?? 0

    switch daysAgo {
    case 0:
      self.init(day: "Today", time: " \(time)")
    case 1:
      self.init(day: "Yesterday", time: " \(time)")
    case 2...6:
      self.init(day: date.formatted(base.weekday(.wide)), time: " \(time)")
    default:
      let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
      let day = base.weekday(.abbreviated).month(.abbreviated).day()
      self.init(
        day: date.formatted(sameYear ? day : day.year()),
        time: " at \(time)"
      )
    }
  }

  var text: String { day + time }
}
