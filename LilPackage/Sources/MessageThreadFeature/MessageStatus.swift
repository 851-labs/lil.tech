import Foundation
import MessagesDatabase

/// The delivery status Messages shows under an outgoing message.
enum MessageStatus: Equatable {
  case delivered
  case notDelivered
  case read(Date)

  /// Failures show under any outgoing message. Delivery and read receipts only show under my latest
  /// message, and only while nothing has come after it.
  static func of(_ message: ThreadMessage, showsReceipt: Bool) -> Self? {
    guard message.isFromMe else { return nil }
    if message.hasError { return .notDelivered }
    guard showsReceipt else { return nil }
    if let dateRead = message.dateRead { return .read(dateRead) }
    return message.isDelivered ? .delivered : nil
  }

  func text(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
    switch self {
    case .delivered:
      "Delivered"
    case .notDelivered:
      "Not Delivered"
    case .read(let date):
      "Read \(readTimestamp(date, now: now, calendar: calendar, locale: locale))"
    }
  }
}

/// When a message was read, like Messages: a time today, "Yesterday", a weekday within the last
/// week, and a short date before that.
func readTimestamp(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
  var calendar = calendar
  calendar.locale = locale
  if calendar.isDate(date, inSameDayAs: now) {
    return date.formatted(
      Date.FormatStyle(
        date: .omitted, time: .shortened, locale: locale, calendar: calendar,
        timeZone: calendar.timeZone)
    )
  }
  if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
    calendar.isDate(date, inSameDayAs: yesterday)
  {
    return "Yesterday"
  }
  let startOfToday = calendar.startOfDay(for: now)
  if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo {
    return date.formatted(
      Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(
        .wide)
    )
  }
  return date.formatted(
    Date.FormatStyle(
      date: .numeric, time: .omitted, locale: locale, calendar: calendar,
      timeZone: calendar.timeZone)
  )
}
