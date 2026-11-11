public import Foundation
import HealthCards

/// A tool's failure, as the toolkit's `HealthToolError`: its message is what the person or agent
/// sees, e.g. an unknown time zone.
public struct HealthToolError: LocalizedError, Equatable, Sendable {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }

  public var errorDescription: String? { message }
}

/// The time zone a call's days and local times are in, and how outputs write them
/// (`Services/api/src/health/tools/ToolTime.ts`): times to the second, rounded down, with their
/// offset (`2026-10-20T08:15:00+01:00`, `+00:00` for UTC), days as `YYYY-MM-DD`.
public struct ToolTime: Sendable {
  /// The name the call gave, echoed as is, or the Mac's own time zone's.
  public let name: String
  public let calendar: Calendar

  /// The time zone named `name` (one of `CardTimeZone.names`, in its proper case), or the Mac's
  /// own without one. Anything else is the call's error, in the remote server's words: an
  /// abbreviation, a UTC offset, or a name in the wrong case.
  public init(timeZone name: String?) throws {
    guard let name else {
      // The Mac's own zone, even one newer than the list.
      self.init(zone: .current, name: TimeZone.current.identifier)
      return
    }
    guard let zone = CardTimeZone.named(name) else {
      if let properName = CardTimeZone.properName(of: name) {
        throw HealthToolError("Unknown time zone: \(name). Did you mean \(properName)?")
      }
      throw HealthToolError("Unknown time zone: \(name). Use an IANA name, e.g. Europe/London.")
    }
    self.init(zone: zone, name: name)
  }

  /// `zone`'s days and local times, named `name`: a call's, or a record's recorded zone
  /// (`RecordedZones`).
  init(zone: TimeZone, name: String) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    self.name = name
    self.calendar = calendar
  }

  public var timeZone: TimeZone { calendar.timeZone }

  /// `date` as a local time with its offset, e.g. `2026-10-20T08:15:00+01:00`.
  public func localTime(_ date: Date) -> String {
    // Rounded down to the second, as the remote server does.
    let date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
    let offset = timeZone.secondsFromGMT(for: date) / 60
    return localDate(date)
      + String(
        format: "T%02d:%02d:%02d%@%02d:%02d", parts.hour ?? 0, parts.minute ?? 0,
        parts.second ?? 0, offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60)
  }

  /// The day `date` falls on, as `YYYY-MM-DD`.
  public func localDate(_ date: Date) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// The start of the day `date` falls on, moved by `days` days.
  public func startOfDay(_ date: Date, adding days: Int = 0) -> Date {
    let start = calendar.startOfDay(for: date)
    return calendar.date(byAdding: .day, value: days, to: start) ?? start
  }

  /// The years the tools take a `date` in (851-4044), as the remote server's `toolYears`. No
  /// Health data is older than 2000, and before the 1970s Foundation's and Node's time zone data
  /// can disagree on a zone's offset. Before 1583 the Gregorian calendar here is Julian, and it has
  /// no year 0, unlike JavaScript's. Up to 2999, so a period's end never has a fifth digit.
  public static let years = 2000...2999

  /// The start of a `YYYY-MM-DD` day, which must exist (not 2026-02-31) and be in `years`, or the
  /// tool's error, in the remote server's words (`toolDate`), for the Health tools and the card
  /// tools alike. The year is checked first, so 1900-02-29 gets the same message on both.
  public func day(_ text: String) throws -> Date {
    func invalid() -> HealthToolError {
      HealthToolError("Invalid date: \(text). Use a day that exists, as YYYY-MM-DD.")
    }
    guard let parts = text.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/),
      let year = Int(parts.1), let month = Int(parts.2), let day = Int(parts.3)
    else { throw invalid() }
    guard Self.years.contains(year) else {
      throw HealthToolError(
        "Invalid date: \(text). Use a day from \(Self.years.lowerBound)-01-01 to "
          + "\(Self.years.upperBound)-12-31.")
    }
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
      calendar.dateComponents([.year, .month, .day], from: date)
        == DateComponents(year: year, month: month, day: day)
    else { throw invalid() }
    return calendar.startOfDay(for: date)
  }
}

/// A tool's period, Health's D, W, M, 6M or Y, ending on a day.
public enum ToolRange: String, CaseIterable, Sendable {
  /// That day, in hours.
  case day = "D"
  /// The 7 days ending that day, in days.
  case week = "W"
  /// The 30 days ending that day, in days.
  case month = "M"
  /// The 26 weeks ending that day, in 7-day weeks.
  case sixMonths = "6M"
  /// The 12 calendar months ending with that day's month, in months; the last ends with the day.
  case year = "Y"
}

/// The period a call asked for: when it starts and ends, and its buckets.
public struct ToolPeriod: Sendable {
  public let range: ToolRange
  public let start: Date
  /// Exclusive: the start of the day after the last.
  public let end: Date
  /// Each bucket's start, oldest first. A bucket runs until the next one's start, the last one
  /// until `end`.
  public let buckets: [Date]

  public var interval: Range<Date> { start..<end }

  /// The period ending on `date` (`YYYY-MM-DD`), or today at `now` without one.
  public init(_ range: ToolRange, date: String?, now: Date, time: ToolTime) throws {
    let lastDay = try date.map(time.day) ?? time.startOfDay(now)
    let calendar = time.calendar
    let end = time.startOfDay(lastDay, adding: 1)
    let start: Date
    let component: Calendar.Component
    let step: Int
    switch range {
    case .day:
      (start, component, step) = (lastDay, .hour, 1)
    case .week:
      (start, component, step) = (time.startOfDay(lastDay, adding: -6), .day, 1)
    case .month:
      (start, component, step) = (time.startOfDay(lastDay, adding: -29), .day, 1)
    case .sixMonths:
      (start, component, step) = (time.startOfDay(lastDay, adding: -181), .day, 7)
    case .year:
      let month = calendar.dateInterval(of: .month, for: lastDay)?.start ?? lastDay
      (start, component, step) = (
        calendar.date(byAdding: .month, value: -11, to: month) ?? month, .month, 1
      )
    }
    var buckets: [Date] = []
    var index = 0
    while let bucket = calendar.date(byAdding: component, value: index * step, to: start),
      bucket < end
    {
      buckets.append(bucket)
      index += 1
    }
    self.range = range
    self.start = start
    self.end = end
    self.buckets = buckets
  }

  /// The bucket a time in the period falls in, by index.
  func bucket(of date: Date) -> Int? {
    guard start <= date, date < end else { return nil }
    // The last bucket that starts by `date`.
    var low = 0
    var high = buckets.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if buckets[middle] <= date { low = middle } else { high = middle - 1 }
    }
    return low
  }
}
