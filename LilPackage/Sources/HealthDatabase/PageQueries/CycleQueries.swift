public import Foundation
import HealthCatalog
public import SQLiteData

extension HealthDatabase {
  public static let menstrualFlowType = "HKCategoryTypeIdentifierMenstrualFlow"
  static let spottingType = "HKCategoryTypeIdentifierIntermenstrualBleeding"
  static let ovulationTestType = "HKCategoryTypeIdentifierOvulationTestResult"
  static let sexualActivityType = "HKCategoryTypeIdentifierSexualActivity"
  static let contraceptiveType = "HKCategoryTypeIdentifierContraceptive"
  static let factorTypes = [
    "HKCategoryTypeIdentifierPregnancy", "HKCategoryTypeIdentifierLactation", contraceptiveType,
  ]
  /// Bleeding other than a period or spotting, marked on the calendar like spotting.
  static let bleedingTypes = [
    "HKCategoryTypeIdentifierBleedingDuringPregnancy",
    "HKCategoryTypeIdentifierBleedingAfterPregnancy",
    "HKCategoryTypeIdentifierBleedingAfterMenopause",
  ]
  /// What a day's log lists by name and value, besides flow, spotting, sexual activity and
  /// symptoms: tests, cervical mucus, factors and other bleeding (851-2830). Menopause and cycle
  /// deviations, which span months, aren't a day's (851-2870, 851-2871).
  static let cycleLogTypes =
    [
      "HKCategoryTypeIdentifierCervicalMucusQuality", ovulationTestType,
      "HKCategoryTypeIdentifierPregnancyTestResult",
      "HKCategoryTypeIdentifierProgesteroneTestResult",
    ] + factorTypes + bleedingTypes

  /// Whether `typeID` opens Cycle Tracking: Health's Cycle Tracking types, but Basal Body
  /// Temperature, a quantity with its own chart.
  public static func opensCycleTracking(_ typeID: String) -> Bool {
    guard let type = HealthCatalog.type(id: typeID) else { return false }
    return type.category == .cycleTracking && type.kind == .category
  }

  /// When `typeID`'s latest sample starts, for Cycle Tracking to open on its month.
  public static func latestSampleStart(of typeID: String, _ db: Database) throws -> Date? {
    try HealthSample
      .where { $0.type.eq(typeID) }
      .select { $0.startDate.max() }
      .fetchOne(db)
      .flatMap { $0 }
      .map(Date.init(unixMilliseconds:))
  }
  /// Symptoms (Health's Symptoms category), shown on the days they were logged.
  static let symptomTypes = HealthCatalog.all.filter { $0.category == .symptoms }.map(\.id)

  /// Each day in `interval` with something Cycle Tracking shows, by the day's start in
  /// `calendar`.
  public static func cycleDays(
    in interval: DateInterval, calendar: Calendar, _ db: Database
  ) throws -> [Date: CycleDay] {
    let types =
      [menstrualFlowType, spottingType, sexualActivityType] + cycleLogTypes + symptomTypes
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
      case sexualActivityType: entry.sexualActivity = true
      case _ where cycleLogTypes.contains(sample.type):
        // Positive (2) or estrogen surge (4), as Health marks the day.
        if sample.type == ovulationTestType, sample.categoryValue == 2 || sample.categoryValue == 4
        {
          entry.ovulationPositive = true
        }
        // No bleeding (5) isn't marked.
        if bleedingTypes.contains(sample.type), sample.categoryValue != 5 { entry.bleeding = true }
        entry.log.append(
          CycleLogEntry(
            name: HealthCatalog.type(id: sample.type)?.name ?? sample.type,
            value: categoryValueName(sample.categoryValue, typeID: sample.type)))
      default:
        // 1 is "not present" (or "no change" for appetite): logged as absent.
        if sample.categoryValue != 1, let name = HealthCatalog.type(id: sample.type)?.name,
          !entry.symptoms.contains(name)
        {
          entry.symptoms.append(name)
        }
      }
      days[day] = entry
    }
    return days
  }

  /// Periods, newest first, at most `limit`: runs of days with flow, a new one after a day
  /// without (or where a sample says a cycle started). Each knows how long its cycle was, up to
  /// the next period. Reads every day with flow, a few a month.
  public static func periods(limit: Int, calendar: Calendar, _ db: Database) throws -> [Period] {
    let none = MenstrualFlow.none.rawValue
    let samples =
      try HealthSample
      .where { $0.type.eq(menstrualFlowType) && $0.categoryValue.isNot(Int?.some(none)) }
      .order(by: \.startDate)
      .fetchAll(db)
    var periods: [Period] = []
    var lastDay: Date?
    for sample in samples {
      let day = calendar.startOfDay(for: Date(unixMilliseconds: sample.startDate))
      if let lastDay, let current = periods.last, !sample.startsCycle,
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

  /// Pregnancy, lactation and contraceptives logged as going on at `now`: ending after it, or
  /// with no end yet (ending as they start).
  public static func cycleFactors(at now: Date, _ db: Database) throws -> [CycleFactor] {
    let moment = now.unixMilliseconds
    return
      try HealthSample
      .where {
        $0.type.in(factorTypes) && $0.startDate <= moment
          && ($0.endDate > moment || $0.endDate.eq($0.startDate))
      }
      .order { $0.startDate.desc() }
      .fetchAll(db)
      .map { sample in
        CycleFactor(
          name: HealthCatalog.type(id: sample.type)?.name ?? sample.type,
          detail: sample.type == contraceptiveType
            ? categoryValueName(sample.categoryValue, typeID: sample.type) : nil,
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
  /// Bleeding during or after pregnancy, or after menopause, marked like spotting.
  public var bleeding = false
  public var ovulationPositive = false
  public var sexualActivity = false
  /// Symptoms' names, as logged.
  public var symptoms: [String] = []
  /// Everything else logged, in the order it was: tests, cervical mucus, factors, bleeding.
  public var log: [CycleLogEntry] = []

  public init(
    flow: MenstrualFlow? = nil, spotting: Bool = false, bleeding: Bool = false,
    ovulationPositive: Bool = false, sexualActivity: Bool = false, symptoms: [String] = [],
    log: [CycleLogEntry] = []
  ) {
    self.flow = flow
    self.spotting = spotting
    self.bleeding = bleeding
    self.ovulationPositive = ovulationPositive
    self.sexualActivity = sexualActivity
    self.symptoms = symptoms
    self.log = log
  }
}

/// Something logged on a day: its type's name, and its value as Health names it, if it has one.
public struct CycleLogEntry: Equatable, Sendable {
  public var name: String
  public var value: String?

  public init(name: String, value: String?) {
    self.name = name
    self.value = value
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
}

extension HealthSample {
  /// Whether its metadata marks the start of a cycle (`HKMetadataKeyMenstrualCycleStart`), as
  /// true or 1.
  var startsCycle: Bool {
    guard let metadata,
      let object = try? JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any],
      let value = object["HKMenstrualCycleStart"]
    else { return false }
    return (value as? Bool) == true || (value as? NSNumber)?.intValue == 1
  }
}
