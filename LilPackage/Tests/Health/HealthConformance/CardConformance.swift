public import Foundation
public import HealthCards

/// One of the cards' conformance cases (851-3198, `Services/api/test/health/cards/conformance`):
/// a card spec run over the period of `range` containing `date`, in a calendar, with the clock at
/// `now`, and the card data every engine must give, as the tools write it. The Mac runs them after
/// syncing the dataset (`CardConformanceTests`), and the iPhone after writing it into HealthKit
/// (851-3201), but for those it `skips`. A case `pending` for an engine (851-4155) is one it
/// doesn't pass yet: that engine runs it and fails when it matches.
public struct CardConformanceCase: Decodable, Sendable, CustomStringConvertible {
  public var name: String
  /// How the expected values come about.
  public var note: String?
  /// An input spec, as apps and tools write it.
  public var spec: ConformanceJSON
  public var range: String
  /// A day, `YYYY-MM-DD`, in the time zone.
  public var date: String
  /// An IANA name; UTC when it's missing, as the tools default.
  public var timeZone: String?
  /// `sunday` to `saturday`; Monday when it's missing, as the tools default.
  public var firstWeekday: String?
  public var now: String
  /// Why the iPhone's engine can't match it, if it can't.
  public var iphone: IPhone?
  /// The tickets that make the engines that don't pass it yet pass it.
  public var pending: Pending?
  public var expected: ConformanceJSON

  public struct IPhone: Decodable, Sendable {
    public var skip: String
  }

  public struct Pending: Decodable, Sendable {
    public var server: String?
    public var mac: String?
    public var iphone: String?
  }

  public var description: String { name }

  public static func cases() throws -> [CardConformanceCase] {
    struct File: Decodable { var cases: [CardConformanceCase] }
    return try JSONDecoder().decode(
      File.self, from: Data(contentsOf: ConformanceFiles.cards.appending(path: "cases.json"))
    )
    .cases
  }

  /// The cards' dataset: the Health tools', then the cards' batches.
  public static func dataset() throws -> [ConformanceBatch] {
    try ConformanceBatch.read(ConformanceFiles.cards.appending(path: "dataset.json"))
  }

  static let weekdays = [
    "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
  ]

  public var timeZoneName: String { timeZone ?? "UTC" }

  /// The engine's calendar: Gregorian, in the time zone, with weeks from the first weekday.
  public func calendar() throws -> Calendar {
    guard let zone = TimeZone(identifier: timeZoneName) else {
      throw ConformanceError("\(name): unknown time zone \(timeZoneName)")
    }
    guard let weekday = Self.weekdays.firstIndex(of: firstWeekday ?? "monday") else {
      throw ConformanceError("\(name): unknown first weekday \(firstWeekday ?? "")")
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    calendar.firstWeekday = weekday + 1
    return calendar
  }

  /// The start of `date` in the calendar.
  public func day(in calendar: Calendar) throws -> Date {
    let parts = date.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
      let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    else { throw ConformanceError("\(name): date \(date) isn't YYYY-MM-DD") }
    return calendar.startOfDay(for: day)
  }

  public func nowDate() throws -> Date {
    try Date(now, strategy: .iso8601)
  }

  public func cardRange() throws -> CardRange {
    guard let range = CardRange(rawValue: range) else {
      throw ConformanceError("\(name): unknown range \(range)")
    }
    return range
  }

  /// The spec, canonicalized and validated as apps and tools do before writing.
  public func cardSpec() throws -> CardSpec {
    try CardSpec(input: CardJSON(parsing: JSONEncoder().encode(spec)))
  }

  /// `data` as the tools write it (docs/decisions/cards.md, Inputs and outputs): the period's
  /// first and last days, and each point's start in local time with its offset, to the second.
  public func json(_ data: CardData, calendar: Calendar) -> ConformanceJSON {
    let time = DateFormatter()
    time.calendar = Calendar(identifier: .gregorian)
    time.locale = Locale(identifier: "en_US_POSIX")
    time.timeZone = calendar.timeZone
    time.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
    let day = DateFormatter()
    day.calendar = time.calendar
    day.locale = time.locale
    day.timeZone = calendar.timeZone
    day.dateFormat = "yyyy-MM-dd"
    func optional(_ value: Double?) -> ConformanceJSON {
      value.map(ConformanceJSON.number) ?? .null
    }
    func string(_ value: String?) -> ConformanceJSON { value.map(ConformanceJSON.string) ?? .null }
    return .object([
      "range": string(data.range?.rawValue),
      "start": .string(day.string(from: data.interval.start)),
      // The period ends at a midnight (or an hour), so its last moment is on its last day.
      "end": .string(day.string(from: data.interval.end.addingTimeInterval(-0.001))),
      "timeZone": .string(timeZoneName),
      "firstWeekday": .string(Self.weekdays[calendar.firstWeekday - 1]),
      "bucket": .string(data.bucket.rawValue),
      "grain": .string(data.grain.rawValue),
      "series": .array(
        data.series.map { series in
          .object([
            "id": .string(series.id),
            "label": .string(series.label),
            "type": .string(series.type),
            "aggregation": .string(series.aggregation.rawValue),
            "unit": .string(series.unit.description),
            "hidden": .bool(series.hidden),
            "points": .array(
              series.points.map { point in
                .object([
                  "start": .string(time.string(from: point.start)),
                  "value": .number(point.value),
                  "minimum": .number(point.minimum),
                  "maximum": .number(point.maximum),
                  "readings": optional(point.readings.map(Double.init)),
                ])
              }),
          ])
        }),
      "formulas": .array(
        data.formulas.map { formula in
          .object([
            "id": .string(formula.id),
            "kind": .string(formula.kind.rawValue),
            "label": string(formula.label),
            "unit": .string(formula.unit.description),
            "hidden": .bool(formula.hidden),
            "points": .array(
              formula.points.map { point in
                .object([
                  "start": .string(time.string(from: point.start)), "value": .number(point.value),
                ])
              }),
          ])
        }),
      "summary": data.summary.map { summary in
        .object([
          "kind": .string(summary.kind.rawValue),
          "value": optional(summary.value),
          "minimum": optional(summary.minimum),
          "maximum": optional(summary.maximum),
        ])
      } ?? .null,
      "goal": optional(data.goal),
    ])
  }
}
