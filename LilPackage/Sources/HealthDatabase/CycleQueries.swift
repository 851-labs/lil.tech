public import Foundation
import HealthCatalog
public import SQLiteData

extension HealthDatabase {
  public static let menstrualFlowType = "HKCategoryTypeIdentifierMenstrualFlow"
  static let spottingType = "HKCategoryTypeIdentifierIntermenstrualBleeding"
  static let ovulationTestType = "HKCategoryTypeIdentifierOvulationTestResult"
  static let sexualActivityType = "HKCategoryTypeIdentifierSexualActivity"
  static let factorTypes = [
    "HKCategoryTypeIdentifierPregnancy", "HKCategoryTypeIdentifierLactation",
    "HKCategoryTypeIdentifierContraceptive",
  ]
  /// Symptoms (Health's Symptoms category), shown on the days they were logged.
  static let symptomTypes = HealthCatalog.all.filter { $0.category == .symptoms }.map(\.id)

  /// Each day in `interval` with something Cycle Tracking shows, by the day's start in
  /// `calendar`.
  public static func cycleDays(
    in interval: DateInterval, calendar: Calendar, _ db: Database
  ) throws -> [Date: CycleDay] {
    let types =
      [menstrualFlowType, spottingType, ovulationTestType, sexualActivityType]
      + symptomTypes
    let (lower, upper) = (interval.start.unixMilliseconds, interval.end.unixMilliseconds)
    let samples =
      try HealthSample
      .where { $0.type.in(types) && $0.startDate >= lower && $0.startDate < upper }
      .order(by: \.startDate)
      .fetchAll(db)
    var days: [Date: CycleDay] = [:]
    for sample in samples {
      let day = calendar.startOfDay(for: Date(unixMilliseconds: sample.startDate))
      var entry = days[day] ?? CycleDay()
      switch sample.type {
      case menstrualFlowType:
        if let flow = MenstrualFlow(rawValue: sample.categoryValue ?? 1), flow != .none {
          entry.flow = max(entry.flow ?? flow, flow)
        }
      case spottingType: entry.spotting = true
      case ovulationTestType:
        // Positive (2) or estrogen surge (4), as Health marks the day.
        if sample.categoryValue == 2 || sample.categoryValue == 4 { entry.ovulationPositive = true }
      case sexualActivityType: entry.sexualActivity = true
      default:
        if let name = HealthCatalog.type(id: sample.type)?.name, !entry.symptoms.contains(name) {
          entry.symptoms.append(name)
        }
      }
      days[day] = entry
    }
    return days
  }

  /// Periods, newest first: runs of days with flow, a new one after a day without (or where the
  /// sample says a cycle started). Each knows how long its cycle was, up to the next period.
  public static func periods(limit: Int, calendar: Calendar, _ db: Database) throws -> [Period] {
    let samples =
      try HealthSample
      .where { $0.type.eq(menstrualFlowType) }
      .order { $0.startDate.desc() }
      .limit(limit * 10)
      .fetchAll(db)
      .reversed()
    var periods: [Period] = []
    var lastDay: Date?
    for sample in samples {
      guard let flow = MenstrualFlow(rawValue: sample.categoryValue ?? 1), flow != .none
      else { continue }
      let day = calendar.startOfDay(for: Date(unixMilliseconds: sample.startDate))
      let started = sample.metadata?.contains(#""HKMenstrualCycleStart":true"#) == true
      if let lastDay, let current = periods.last, !started,
        let gap = calendar.dateComponents([.day], from: lastDay, to: day).day, gap <= 1
      {
        periods[periods.count - 1].end = max(current.end, day)
      } else if lastDay != day {
        periods.append(Period(start: day, end: day))
      }
      lastDay = day
    }
    for index in periods.indices.dropLast() {
      periods[index].cycleLength =
        calendar.dateComponents([.day], from: periods[index].start, to: periods[index + 1].start)
        .day
    }
    return Array(periods.reversed().prefix(limit))
  }

  /// Pregnancy, lactation and contraceptives logged as going on at `now`.
  public static func cycleFactors(at now: Date, _ db: Database) throws -> [CycleFactor] {
    let moment = now.unixMilliseconds
    return
      try HealthSample
      .where { $0.type.in(factorTypes) && $0.startDate <= moment && $0.endDate > moment }
      .order { $0.startDate.desc() }
      .fetchAll(db)
      .map { sample in
        CycleFactor(
          name: HealthCatalog.type(id: sample.type)?.name ?? sample.type,
          detail: sample.type == "HKCategoryTypeIdentifierContraceptive"
            ? CycleFactor.contraceptive(sample.categoryValue) : nil,
          since: Date(unixMilliseconds: sample.startDate))
      }
  }
}

/// How much flow a day had (`HKCategoryValueVaginalBleeding`).
public enum MenstrualFlow: Int, Comparable, Sendable {
  case unspecified = 1
  case light, medium, heavy, none

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

  private var rank: Int {
    switch self {
    case .none: 0
    case .unspecified: 1
    case .light: 2
    case .medium: 3
    case .heavy: 4
    }
  }

  public var name: String {
    switch self {
    case .unspecified: "Period"
    case .light: "Light Flow"
    case .medium: "Medium Flow"
    case .heavy: "Heavy Flow"
    case .none: "No Flow"
    }
  }
}

/// What a day had, for the calendar.
public struct CycleDay: Equatable, Sendable {
  public var flow: MenstrualFlow?
  public var spotting = false
  public var ovulationPositive = false
  public var sexualActivity = false
  /// Symptoms' names, as logged.
  public var symptoms: [String] = []

  public init(
    flow: MenstrualFlow? = nil, spotting: Bool = false, ovulationPositive: Bool = false,
    sexualActivity: Bool = false, symptoms: [String] = []
  ) {
    self.flow = flow
    self.spotting = spotting
    self.ovulationPositive = ovulationPositive
    self.sexualActivity = sexualActivity
    self.symptoms = symptoms
  }
}

/// A period: its first and last days, and its cycle's length in days (to the next period's
/// start), unless it's the latest.
public struct Period: Equatable, Sendable {
  public var start: Date
  public var end: Date
  public var cycleLength: Int?

  public init(start: Date, end: Date, cycleLength: Int? = nil) {
    self.start = start
    self.end = end
    self.cycleLength = cycleLength
  }

  /// Days with flow, first to last.
  public func length(_ calendar: Calendar) -> Int {
    (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
  }
}

/// Something that affects cycles, going on now.
public struct CycleFactor: Equatable, Sendable {
  public var name: String
  /// For contraceptives, which kind.
  public var detail: String?
  public var since: Date

  public init(name: String, detail: String?, since: Date) {
    self.name = name
    self.detail = detail
    self.since = since
  }

  /// `HKCategoryValueContraceptive`'s names.
  static func contraceptive(_ value: Int?) -> String? {
    switch value {
    case 2: "Implant"
    case 3: "Injection"
    case 4: "Intrauterine Device"
    case 5: "Intravaginal Ring"
    case 6: "Oral"
    case 7: "Patch"
    default: nil
    }
  }
}
