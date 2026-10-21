public import Foundation
public import HealthCatalog
import HealthDatabase
public import SQLiteData

/// The Health toolkit's tools (`Services/api/src/health/tools/HealthToolkit.ts`, 851-2841) on the
/// Mac's database: `lil-health`'s commands, and the tools of its MCP server (851-2844). Each reads
/// with the queries the app's screens use, so answers match the app, and answers as the toolkit's
/// output schemas have it, so they match the remote MCP server's.
///
/// A call's days and local times are in its time zone, by default the Mac's.
public struct HealthTools: Sendable {
  public var now: Date

  public init(now: Date = Date()) {
    self.now = now
  }

  /// What `summary` shows when nothing is pinned: the Mac's Summary suggestions.
  public static let summaryDefaultTypes = [
    "HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierHeartRate",
    "HKQuantityTypeIdentifierActiveEnergyBurned",
    "HKQuantityTypeIdentifierDistanceWalkingRunning",
    "HKQuantityTypeIdentifierRestingHeartRate", "HKQuantityTypeIdentifierBodyMass",
  ]

  /// The most samples one call returns, and how many it returns by default.
  public static let samplesLimit = 500
  public static let samplesDefaultLimit = 100
  /// The most workouts one call lists.
  public static let workoutsLimit = 100

  // MARK: - summary

  /// For each pinned type (else `summaryDefaultTypes`), its latest sample that has started, and
  /// from the statistics source its totals today and over the last 7 days (skipping empty
  /// buckets); plus the workouts that started in those 7 days, by now.
  public func summary(timeZone: String? = nil, _ db: Database) throws -> HealthSummaryResult {
    let time = try ToolTime(timeZone: timeZone)
    let today = time.startOfDay(now)
    let tomorrow = time.startOfDay(now, adding: 1)
    let weekStart = time.startOfDay(now, adding: -6)
    let pins = try HealthDatabase.summaryPins(db)
    let metrics = try (pins.isEmpty ? Self.summaryDefaultTypes : pins).map { type in
      let latest = try HealthDatabase.latestSample(of: type, startedBy: now, db)
      let days = try HealthDatabase.cumulativeStatistics(
        of: type, in: weekStart..<tomorrow, by: .day, calendar: time.calendar, now: now, db)
      let todays = days.filter { $0.start >= today }
      return HealthSummaryMetric(
        type: type,
        unit: latest?.unit ?? (days.isEmpty ? nil : HealthCatalog.type(id: type)?.unit),
        latest: latest.map {
          HealthSummaryMetric.Latest(
            start: time.localTime($0.start), end: time.localTime($0.end), value: $0.value,
            categoryValue: $0.categoryValue)
        },
        today: todays.isEmpty ? nil : todays.reduce(0) { $0 + $1.sum },
        last7Days: days.isEmpty ? nil : days.reduce(0) { $0 + $1.sum })
    }
    // A workout an app dated later today hasn't happened.
    let workouts = try HealthDatabase.workoutTotals(
      in: weekStart..<min(tomorrow, now.nextMillisecond), db)
    return HealthSummaryResult(
      timeZone: time.name, date: time.localDate(now), pinned: !pins.isEmpty, metrics: metrics,
      workouts: .init(count: workouts.count, duration: workouts.duration))
  }

  // MARK: - list_types

  /// Every type with data, by category (in Health's order), then name.
  public func listTypes(timeZone: String? = nil, _ db: Database) throws -> HealthTypesResult {
    let time = try ToolTime(timeZone: timeZone)
    let dates = try HealthDatabase.typeDates(calendar: time.calendar, db)
    let types = HealthCatalog.all
      .filter { dates[$0.id] != nil }
      .sorted(by: Self.byCategoryThenName)
      .compactMap { type -> HealthTypeInfo? in
        guard let range = dates[type.id] else { return nil }
        return HealthTypeInfo(
          type: type.id, name: type.name, category: type.category?.name,
          kind: type.kind.rawValue, unit: type.kind == .quantity ? type.unit : nil,
          cumulative: type.aggregation?.isCumulative == true,
          first: time.localTime(range.first), last: time.localTime(range.last))
      }
    return HealthTypesResult(timeZone: time.name, types: types)
  }

  // MARK: - metric

  /// The statistics `metric` computes.
  public enum Statistic: String, CaseIterable, Sendable {
    case sum, average, minimum, maximum
  }

  /// A quantity type's statistic over a period, overall and per bucket.
  ///
  /// - Types that add up (steps): totals come from the statistics source's buckets, and the
  ///   samples' own past them, as the app's charts. `sum` is the total; `average`, `minimum` and
  ///   `maximum` are of the days' totals (days with data), as Health's Daily Average, except for
  ///   a D range's hours, which are each hour's total.
  /// - Other types (heart rate): from the samples, weighted by the type's aggregation style, as
  ///   the app's charts. They don't add up, so `sum` is an error.
  public func metric(
    type: String, range: ToolRange, statistic: Statistic? = nil, date: String? = nil,
    timeZone: String? = nil, _ db: Database
  ) throws -> HealthMetricResult {
    let time = try ToolTime(timeZone: timeZone)
    let type = try Self.dataType(type)
    guard type.kind == .quantity, let aggregation = type.aggregation else {
      throw HealthToolError(
        "\(type.name) (\(type.id)) isn't a quantity type, so it has no statistics. Use samples, "
          + "or the tool for its kind (sleep, workouts, medications).")
    }
    let period = try ToolPeriod(range, date: date, now: now, time: time)
    let cumulative = aggregation.isCumulative
    let statistic = statistic ?? (cumulative ? .sum : .average)
    var buckets: [Double?]
    let value: Double?
    if cumulative {
      // Days' totals, or a D range's hours'.
      let totals = try HealthDatabase.cumulativeTotals(
        of: type.id, in: period.interval, by: range == .day ? .hour : .day, now: now,
        calendar: time.calendar, db)
      var grouped = [[Double]](repeating: [], count: period.buckets.count)
      for total in totals {
        if let index = period.bucket(of: total.start) { grouped[index].append(total.sum) }
      }
      buckets = grouped.map { Self.combine($0, statistic) }
      value = Self.combine(totals.map(\.sum), range == .day ? .sum : statistic)
    } else {
      guard statistic != .sum else {
        throw HealthToolError(
          "\(type.name) doesn't add up, so it has no sum. Use average, minimum or maximum.")
      }
      let starts = period.buckets
      buckets = try starts.indices.map { index in
        let end = index + 1 < starts.count ? starts[index + 1] : period.end
        return try HealthDatabase.discreteStatistic(of: type.id, in: starts[index]..<end, db)
          .map { Self.value(of: $0, statistic) }
      }
      value = try HealthDatabase.discreteStatistic(of: type.id, in: period.interval, db)
        .map { Self.value(of: $0, statistic) }
    }
    return HealthMetricResult(
      timeZone: time.name, range: range.rawValue, start: time.localTime(period.start),
      end: time.localTime(period.end), type: type.id, unit: type.unit,
      statistic: statistic.rawValue, value: value,
      buckets: zip(period.buckets, buckets).map {
        HealthMetricBucket(start: time.localTime($0), value: $1)
      })
  }

  private static func combine(_ values: [Double], _ statistic: Statistic) -> Double? {
    guard !values.isEmpty else { return nil }
    switch statistic {
    case .sum: return values.reduce(0, +)
    case .average: return values.reduce(0, +) / Double(values.count)
    case .minimum: return values.min()
    case .maximum: return values.max()
    }
  }

  private static func value(of statistic: DiscreteStatistic, _ kind: Statistic) -> Double {
    switch kind {
    case .sum, .average: statistic.average
    case .minimum: statistic.minimum
    case .maximum: statistic.maximum
    }
  }

  // MARK: - samples

  /// A quantity or category type's samples that start in the period, newest first, a page at a
  /// time.
  public func samples(
    type: String, range: ToolRange, date: String? = nil, timeZone: String? = nil,
    cursor: String? = nil, limit: Int? = nil, _ db: Database
  ) throws -> HealthSamplesResult {
    let time = try ToolTime(timeZone: timeZone)
    let type = try Self.dataType(type)
    guard type.kind == .quantity || type.kind == .category else {
      throw HealthToolError(
        "\(type.name) (\(type.id)) isn't a quantity or category type, so it has no samples. Use "
          + "the tool for its kind (workouts, medications, health_details).")
    }
    let limit = limit ?? Self.samplesDefaultLimit
    guard (1...Self.samplesLimit).contains(limit) else {
      throw HealthToolError("The limit must be from 1 to \(Self.samplesLimit).")
    }
    let period = try ToolPeriod(range, date: date, now: now, time: time)
    let after = try cursor.map(Self.sampleCursor)
    // One more than asked for, to know whether there's another page.
    let page = try HealthDatabase.samplePage(
      of: type.id, in: period.interval, after: after, limit: limit + 1, db)
    let samples = page.prefix(limit)
    return HealthSamplesResult(
      timeZone: time.name, range: range.rawValue, start: time.localTime(period.start),
      end: time.localTime(period.end), type: type.id,
      samples: samples.map {
        HealthSampleItem(
          id: $0.id, start: time.localTime($0.start), end: time.localTime($0.end),
          value: $0.value, unit: $0.unit, categoryValue: $0.categoryValue, source: $0.sourceName)
      },
      nextCursor: page.count > limit ? samples.last.map(Self.cursor(after:)) : nil)
  }

  /// A page's cursor: where its last sample starts, and its ID, which breaks ties.
  private static func cursor(after sample: HealthSample) -> String {
    "\(sample.startDate)_\(sample.id)"
  }

  private static func sampleCursor(_ text: String) throws -> SampleCursor {
    let parts = text.split(separator: "_", maxSplits: 1)
    guard parts.count == 2, let start = Int(parts[0]) else {
      throw HealthToolError("Invalid cursor: \(text). Pass the previous page's nextCursor.")
    }
    return SampleCursor(startDate: start, id: String(parts[1]))
  }

  // MARK: - workouts

  /// Workouts that started in the period, newest first, at most `workoutsLimit`, with the
  /// period's count and total time.
  public func workouts(
    range: ToolRange, date: String? = nil, timeZone: String? = nil, _ db: Database
  ) throws -> HealthWorkoutsResult {
    let time = try ToolTime(timeZone: timeZone)
    let period = try ToolPeriod(range, date: date, now: now, time: time)
    let totals = try HealthDatabase.workoutTotals(in: period.interval, db)
    let workouts = try HealthDatabase.workouts(
      in: period.interval, limit: Self.workoutsLimit, db)
    return HealthWorkoutsResult(
      timeZone: time.name, range: range.rawValue, start: time.localTime(period.start),
      end: time.localTime(period.end), count: totals.count, duration: totals.duration,
      workouts: workouts.map { workout in
        let statistics = workout.decodedStatistics
        return HealthWorkoutItem(
          id: workout.id, activityType: workout.activityType,
          activity: HealthCatalog.workoutActivityName(workout.activityType),
          start: time.localTime(Date(unixMilliseconds: workout.startDate)),
          end: time.localTime(Date(unixMilliseconds: workout.endDate)),
          duration: workout.duration,
          activeEnergy: statistics[HealthWorkout.activeEnergyType]?.sum,
          distance: HealthWorkout.distance(in: statistics),
          averageHeartRate: statistics[HealthWorkout.heartRateType]?.average,
          source: workout.sourceName)
      })
  }

  // MARK: - sleep

  /// Each night that ends in the period, oldest first, as the app's Sleep page has them.
  public func sleep(
    range: ToolRange, date: String? = nil, timeZone: String? = nil, _ db: Database
  ) throws -> HealthSleepResult {
    let time = try ToolTime(timeZone: timeZone)
    let period = try ToolPeriod(range, date: date, now: now, time: time)
    let lastDay = time.startOfDay(period.end, adding: -1)
    let days = (time.calendar.dateComponents([.day], from: period.start, to: lastDay).day ?? 0) + 1
    let nights = try HealthDatabase.sleepNights(
      endingOn: lastDay, count: days, calendar: time.calendar, db)
    return HealthSleepResult(
      timeZone: time.name, range: range.rawValue, start: time.localTime(period.start),
      end: time.localTime(period.end),
      nights: nights.compactMap { night in
        guard let start = night.segments.map(\.start).min(),
          let end = night.segments.map(\.end).max()
        else { return nil }
        let durations = night.durations
        return HealthSleepNight(
          date: time.localDate(night.day), start: time.localTime(start),
          end: time.localTime(end), inBed: night.inBed, asleep: night.asleep,
          awake: durations[.awake] ?? 0, core: durations[.core] ?? 0,
          deep: durations[.deep] ?? 0, rem: durations[.rem] ?? 0,
          unspecified: durations[.asleep] ?? 0)
      })
  }

  // MARK: - medications

  /// Every shared medication, current ones then archived ones, by name, with its adherence over
  /// the last 7 and 30 days and when it was last taken.
  public func medications(timeZone: String? = nil, _ db: Database) throws
    -> HealthMedicationsResult
  {
    let time = try ToolTime(timeZone: timeZone)
    let medications = try HealthDatabase.medications(db).map { medication in
      let detail = try HealthDatabase.medicationDetail(
        id: medication.id, now: now, calendar: time.calendar, limit: 1, db)
      func adherence(_ days: Int) -> HealthMedicationAdherence {
        let adherence = detail?.adherence.first { $0.days == days }
        return HealthMedicationAdherence(
          scheduled: adherence?.scheduled ?? 0, taken: adherence?.taken ?? 0,
          asNeeded: adherence?.takenAsNeeded ?? 0)
      }
      return HealthMedicationItem(
        id: medication.id, name: medication.displayName, healthName: medication.name,
        form: medication.generalForm, archived: medication.isArchived,
        scheduled: medication.hasSchedule, last7Days: adherence(7), last30Days: adherence(30),
        lastTaken: try HealthDatabase.lastTaken(medication: medication.id, db).map(
          time.localTime))
    }
    return HealthMedicationsResult(timeZone: time.name, medications: medications)
  }

  // MARK: - health_details

  /// The characteristics Health Details shows, and the vision prescriptions, newest first.
  public func healthDetails(timeZone: String? = nil, _ db: Database) throws
    -> HealthDetailsResult
  {
    let time = try ToolTime(timeZone: timeZone)
    let details = HealthDetails(characteristics: try HealthDatabase.characteristics(db))
    let prescriptions = try HealthDatabase.visionPrescriptions(limit: .max, db)
    func lens(_ lens: VisionLens?) -> HealthLens? {
      lens.map {
        HealthLens(sphere: $0.sphere, cylinder: $0.cylinder, axis: $0.axis, addPower: $0.addPower)
      }
    }
    return HealthDetailsResult(
      timeZone: time.name,
      dateOfBirth: details.dateOfBirth.map {
        String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day)
      },
      age: details.dateOfBirth?.age(at: now, calendar: time.calendar),
      sex: details.sex?.rawValue,
      // ASCII signs, rather than the app's minus (A−).
      bloodType: details.bloodType.map { $0.name.replacingOccurrences(of: "−", with: "-") },
      fitzpatrickSkinType: details.skinType?.rawValue,
      wheelchairUse: details.wheelchairUse.map { $0 == .yes },
      visionPrescriptions: prescriptions.map { prescription in
        HealthVisionPrescriptionItem(
          id: prescription.id,
          kind: prescription.kind.map { $0 == .glasses ? "glasses" : "contacts" } ?? "unknown",
          issued: time.localDate(prescription.issued),
          expires: prescription.expires.map(time.localDate), brand: prescription.brand,
          rightEye: lens(prescription.decodedRightEye), leftEye: lens(prescription.decodedLeftEye))
      })
  }

  // MARK: - search

  /// Every type lil health knows whose name or category has each of the query's words (or whose
  /// identifier does: `vo2` finds Cardio Fitness), those with data first; and medications whose
  /// name has them.
  public func search(query: String, _ db: Database) throws -> HealthSearchResult {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty, query.count <= 100 else {
      throw HealthToolError("The query must be 1 to 100 characters, and not only spaces.")
    }
    func matches(_ text: String) -> Bool {
      let text = text.lowercased()
      return words.allSatisfy { text.contains($0) }
    }
    let dates = try HealthDatabase.typeDates(calendar: Calendar(identifier: .gregorian), db)
    let hasMedications = try HealthMedication.select(\.id).limit(1).fetchOne(db) != nil
    func hasData(_ type: HealthDataType) -> Bool {
      dates[type.id] != nil || (type.kind == .medication && hasMedications)
    }
    let types = HealthCatalog.all
      .filter { matches("\($0.name) \($0.category?.name ?? "") \(Self.shortID($0.id))") }
      .sorted { a, b in
        hasData(a) != hasData(b) ? hasData(a) : Self.byCategoryThenName(a, b)
      }
      .map {
        HealthSearchType(
          type: $0.id, name: $0.name, category: $0.category?.name, hasData: hasData($0))
      }
    let medications = try HealthDatabase.medications(db)
      .filter { matches("\($0.displayName) \($0.name)") }
      .map { HealthSearchMedication(id: $0.id, name: $0.displayName) }
    return HealthSearchResult(types: types, medications: medications)
  }

  // MARK: - sync_status

  /// The newest sample that has started, and each iPhone that reports statistics, most recently
  /// reported first, saying which one totals come from.
  public func syncStatus(timeZone: String? = nil, _ db: Database) throws -> HealthSyncStatusResult {
    let time = try ToolTime(timeZone: timeZone)
    let source = try HealthDatabase.statisticsSource(db, now: now)
    let devices = try HealthStatisticsDevice.all.fetchAll(db)
      .sorted { ($0.reportedAt, $0.device) > ($1.reportedAt, $1.device) }
    return HealthSyncStatusResult(
      timeZone: time.name,
      latestSample: try HealthDatabase.latestSampleStart(startedBy: now, db).map(time.localTime),
      iPhones: devices.map {
        HealthSyncIPhone(
          device: $0.device, pairedWithWatch: $0.pairedWithWatch,
          lastReported: time.localTime(Date(unixMilliseconds: $0.reportedAt)),
          statisticsSource: $0.device == source)
      })
  }

  // MARK: - Types

  /// The type a call names: by its HealthKit identifier, as the toolkit's tools take it, or, for
  /// people typing commands, by the name Health shows (`Steps`, `heart rate`) or the identifier
  /// without its prefix (`StepCount`), in any case.
  public static func dataType(_ name: String) throws -> HealthDataType {
    if let type = HealthCatalog.type(id: name) { return type }
    let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
    let match =
      HealthCatalog.all.first { $0.name.lowercased() == wanted }
      ?? HealthCatalog.all.first { shortID($0.id).lowercased() == wanted }
    guard let match else {
      throw HealthToolError(
        "Unknown type: \(name). Use a HealthKit identifier, e.g. "
          + "HKQuantityTypeIdentifierStepCount; search finds them.")
    }
    return match
  }

  /// An identifier without HealthKit's prefix: `StepCount` for
  /// `HKQuantityTypeIdentifierStepCount`.
  static func shortID(_ id: String) -> String {
    guard let range = id.range(of: "TypeIdentifier") else { return id }
    return String(id[range.upperBound...])
  }

  private static func byCategoryThenName(_ a: HealthDataType, _ b: HealthDataType) -> Bool {
    let order = { (type: HealthDataType) in
      type.category.flatMap { HealthCategory.allCases.firstIndex(of: $0) }
        ?? HealthCategory.allCases.count
    }
    if order(a) != order(b) { return order(a) < order(b) }
    return a.name.localizedStandardCompare(b.name) == .orderedAscending
  }
}

extension Date {
  /// The next millisecond, so a range up to it includes this one.
  fileprivate var nextMillisecond: Date { addingTimeInterval(0.001) }
}
