public import Foundation
import HealthCatalog
public import SQLiteData

extension HealthDatabase {
  public static let menstrualFlowType = "HKCategoryTypeIdentifierMenstrualFlow"
  static let spottingType = "HKCategoryTypeIdentifierIntermenstrualBleeding"
  static let ovulationTestType = "HKCategoryTypeIdentifierOvulationTestResult"
  static let sexualActivityType = "HKCategoryTypeIdentifierSexualActivity"
  static let contraceptiveType = "HKCategoryTypeIdentifierContraceptive"
  static let menopausalStateType = "HKCategoryTypeIdentifierMenopausalState"
  static let factorTypes = [
    "HKCategoryTypeIdentifierPregnancy", "HKCategoryTypeIdentifierLactation", contraceptiveType,
  ]
  /// Bleeding other than a period or spotting, marked on the calendar like spotting.
  static let bleedingTypes = [
    "HKCategoryTypeIdentifierBleedingDuringPregnancy",
    "HKCategoryTypeIdentifierBleedingAfterPregnancy",
    "HKCategoryTypeIdentifierBleedingAfterMenopause",
  ]
  /// What Health flags from the last 6 months of logged periods and spotting, once the person
  /// confirms it (iOS 16).
  static let cycleDeviationTypes = [
    "HKCategoryTypeIdentifierInfrequentMenstrualCycles",
    "HKCategoryTypeIdentifierIrregularMenstrualCycles",
    "HKCategoryTypeIdentifierPersistentIntermenstrualBleeding",
    "HKCategoryTypeIdentifierProlongedMenstrualPeriods",
  ]
  /// What a day's log lists by name and value, on the day each starts: every Cycle Tracking
  /// category type but flow, spotting and sexual activity, which have their own marks (851-2830).
  /// Factors, menopause and cycle deviations go on for months: the day they start says so, though
  /// each has a section of its own too (851-2870, 851-2871).
  static let cycleLogTypes = HealthCatalog.all
    .filter { $0.category == .cycleTracking && $0.kind == .category }
    .map(\.id)
    .filter { ![menstrualFlowType, spottingType, sexualActivityType].contains($0) }

  /// Whether `typeID` opens Cycle Tracking: Health's Cycle Tracking types, but Basal Body
  /// Temperature, a quantity with its own chart.
  public static func opensCycleTracking(_ typeID: String) -> Bool {
    guard let type = HealthCatalog.type(id: typeID) else { return false }
    return type.category == .cycleTracking && type.kind == .category
  }

  /// Symptoms (Health's Symptoms category), shown on the days they were logged.
  static let symptomTypes = Set(
    HealthCatalog.all.filter { $0.category == .symptoms }.map(\.id))

  /// Each day in `interval` with something Cycle Tracking shows, by the day's start in
  /// `calendar`.
  public static func cycleDays(
    in interval: DateInterval, calendar: Calendar, _ db: Database
  ) throws -> [Date: CycleDay] {
    let types =
      [menstrualFlowType, spottingType, sexualActivityType] + cycleLogTypes
      + symptomTypes.sorted()
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
        // Not present (no change, for appetite) is logged as absent, as the symptom page has it.
        if SymptomScale(typeID: sample.type)?.level(sample.categoryValue) != nil,
          let name = HealthCatalog.type(id: sample.type)?.name,
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
  /// with no end yet (ending as they start). Newest first.
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
      .map { cycleFactor($0, now: moment) }
  }

  /// Pregnancy, lactation and contraceptives that ended by `now`, the latest to end first, at
  /// most `limit`: Health's past factors (Show All Factors), the ones `cycleFactors(at:)` leaves
  /// out.
  public static func cycleFactorHistory(
    before now: Date, limit: Int, _ db: Database
  ) throws -> [CycleFactor] {
    let moment = now.unixMilliseconds
    return
      try HealthSample
      .where { $0.type.in(factorTypes) && $0.endDate <= moment && $0.endDate > $0.startDate }
      .order { ($0.endDate.desc(), $0.startDate.desc()) }
      .limit(limit)
      .fetchAll(db)
      .map { cycleFactor($0, now: moment) }
  }

  /// A factor sample, with its end if it's over by `now`.
  private static func cycleFactor(_ sample: HealthSample, now: Int) -> CycleFactor {
    CycleFactor(
      name: HealthCatalog.type(id: sample.type)?.name ?? sample.type,
      detail: sample.type == contraceptiveType
        ? categoryValueName(sample.categoryValue, typeID: sample.type) : nil,
      start: Date(unixMilliseconds: sample.startDate),
      end: sample.endDate == sample.startDate || sample.endDate > now
        ? nil : Date(unixMilliseconds: sample.endDate))
  }

  /// HKCategoryValueMenopausalState's None: no stage to show.
  static let noMenopausalStage = 3

  /// The menopause stage going on at `now` (`HKCategoryTypeIdentifierMenopausalState`, iOS 27),
  /// as factors are: the last logged by then, unless it's over (it ended by then) or says None.
  /// Since the start of its latest unbroken run: the samples before it with the same value, each
  /// going on until the next starts.
  public static func menopauseStage(at now: Date, _ db: Database) throws -> MenopauseStage? {
    let moment = now.unixMilliseconds
    // A few samples in a lifetime.
    let samples =
      try HealthSample
      .where { $0.type.eq(menopausalStateType) && $0.startDate <= moment }
      .order { ($0.startDate.desc(), $0.endDate.desc()) }
      .fetchAll(db)
    guard let latest = samples.first, latest.categoryValue != noMenopausalStage,
      latest.endDate > moment || latest.endDate == latest.startDate
    else { return nil }
    var since = latest.startDate
    for earlier in samples.dropFirst() {
      let isOverBefore = earlier.endDate > earlier.startDate && earlier.endDate < since
      guard earlier.categoryValue == latest.categoryValue, !isOverBefore else { break }
      since = earlier.startDate
    }
    return MenopauseStage(
      name: categoryValueName(latest.categoryValue, typeID: latest.type),
      since: Date(unixMilliseconds: since))
  }

  /// Cycle deviations Health flagged that ended by `now`, newest first (by start, then end), at
  /// most `limit`. Health's are retrospective, over the months it looked at, so they've always
  /// ended; one that ends later isn't shown until it has. All of them, not only the last 6
  /// months': that's the window Health looks at to flag one, and each keeps its own dates.
  public static func cycleDeviations(
    before now: Date, limit: Int, _ db: Database
  ) throws -> [CycleDeviation] {
    let moment = now.unixMilliseconds
    return
      try HealthSample
      .where { $0.type.in(cycleDeviationTypes) && $0.endDate <= moment }
      .order { ($0.startDate.desc(), $0.endDate.desc()) }
      .limit(limit)
      .fetchAll(db)
      .map {
        CycleDeviation(
          name: HealthCatalog.type(id: $0.type)?.name ?? $0.type,
          start: Date(unixMilliseconds: $0.startDate), end: Date(unixMilliseconds: $0.endDate))
      }
  }

  /// When what `cycleFactors(at:)`, `cycleFactorHistory(before:limit:)`,
  /// `menopauseStage(at:)` and `cycleDeviations(before:limit:)` say next changes after `now`,
  /// without a sync: the first factor or stage to start or end later, or deviation to end. Nil if
  /// nothing does.
  public static func nextCycleChange(after now: Date, _ db: Database) throws -> Date? {
    let moment = now.unixMilliseconds
    let types = factorTypes + [menopausalStateType]
    let start =
      try HealthSample
      .where { $0.type.in(types) && $0.startDate > moment }
      .order(by: \.startDate)
      .limit(1)
      .fetchOne(db)?
      .startDate
    let end =
      try HealthSample
      .where { $0.type.in(types) && $0.endDate > moment && $0.endDate > $0.startDate }
      .order(by: \.endDate)
      .limit(1)
      .fetchOne(db)?
      .endDate
    // Shown once it ends, even if it ends as it starts.
    let deviationEnd =
      try HealthSample
      .where { $0.type.in(cycleDeviationTypes) && $0.endDate > moment }
      .order(by: \.endDate)
      .limit(1)
      .fetchOne(db)?
      .endDate
    return [start, end, deviationEnd].compactMap { $0 }.min().map { Date(unixMilliseconds: $0) }
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

/// Something that affects cycles: pregnancy, lactation or a contraceptive, going on since
/// `start`, or over between `start` and `end`.
public struct CycleFactor: Equatable, Sendable {
  public var name: String
  /// For contraceptives, which kind.
  public var detail: String?
  public var start: Date
  /// When it ended, for a past one. Nil while it goes on.
  public var end: Date?

  public init(name: String, detail: String?, start: Date, end: Date? = nil) {
    self.name = name
    self.detail = detail
    self.start = start
    self.end = end
  }
}

/// A cycle deviation Health flagged, as it names it ("Irregular Cycles"), over the months it
/// covers.
public struct CycleDeviation: Equatable, Sendable {
  public var name: String
  public var start: Date
  public var end: Date

  public init(name: String, start: Date, end: Date) {
    self.name = name
    self.start = start
    self.end = end
  }
}

/// The menopause stage going on, as Health names it ("Perimenopause"), and since when. No name
/// for a value Health doesn't have yet.
public struct MenopauseStage: Equatable, Sendable {
  public var name: String?
  public var since: Date

  public init(name: String?, since: Date) {
    self.name = name
    self.since = since
  }
}

extension HealthSample {
  /// Whether its metadata marks the start of a cycle (`HKMetadataKeyMenstrualCycleStart`), as
  /// true or 1.
  var startsCycle: Bool {
    guard let value = metadataObject["HKMenstrualCycleStart"] else { return false }
    return (value as? Bool) == true || (value as? NSNumber)?.intValue == 1
  }
}
