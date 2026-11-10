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
  /// The IANA name of the time zone for calls that don't give one, or `nil` for the Mac's (UTC
  /// where the conformance cases expect the remote server's default).
  public var defaultTimeZone: String?
  /// A health blob's bytes, by its SHA-256: a route's points (851-4164), which the app downloads
  /// when they're needed, as its pages do.
  public var blob: @Sendable (_ sha256: String) throws -> Data

  public init(
    now: Date = Date(), defaultTimeZone: String? = nil,
    blob: @escaping @Sendable (_ sha256: String) throws -> Data = { _ in
      throw HealthToolError("lil health's data on this Mac has no route points.")
    }
  ) {
    self.now = now
    self.defaultTimeZone = defaultTimeZone
    self.blob = blob
  }

  /// The most samples one call returns, and how many it returns by default.
  public static let samplesLimit = 500
  public static let samplesDefaultLimit = 100
  /// The most workouts one call lists.
  public static let workoutsLimit = 100

  // MARK: - summary

  /// For each of Summary's metrics (`HealthDatabase.summaryTypes`), its latest sample that has
  /// started, and from the statistics source its totals today and over the last 7 days (skipping
  /// empty buckets); plus the workouts that started in those 7 days, by now.
  public func summary(timeZone: String? = nil, _ db: Database) throws -> HealthSummaryResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    let today = time.startOfDay(now)
    let tomorrow = time.startOfDay(now, adding: 1)
    let weekStart = time.startOfDay(now, adding: -6)
    let metrics = try HealthDatabase.summaryTypes.map { type in
      // A series's most recent value, not its average (851-4171).
      let latest = try HealthDatabase.latestReading(of: type, startedBy: now, db)
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
      timeZone: time.name, date: time.localDate(now), pinned: false, metrics: metrics,
      workouts: .init(count: workouts.count, duration: workouts.duration))
  }

  // MARK: - list_types

  /// Every type with data, by category (in Health's order), then name.
  public func listTypes(timeZone: String? = nil, _ db: Database) throws -> HealthTypesResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
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
  ///   `maximum` are of the days' totals (days with data), as Metric Detail's header average
  ///   (AVERAGE for W and M, DAILY AVERAGE for 6M and Y), or of a D range's hours' totals.
  /// - Other types (heart rate): from the samples, weighted by the type's aggregation style, as
  ///   the app's charts. They don't add up, so `sum` is an error.
  public func metric(
    type: String, range: ToolRange, statistic: Statistic? = nil, date: String? = nil,
    timeZone: String? = nil, _ db: Database
  ) throws -> HealthMetricResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
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
      value = Self.combine(totals.map(\.sum), statistic)
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

  /// A quantity, category or correlation type's samples that start in the period, newest first,
  /// a page at a time, each with its source, device and metadata (`SampleDetails`), a
  /// correlation with the samples it groups, and a quantity series (851-4171) with its count and
  /// summary. With `seriesValues`, each series whose values were uploaded is its values instead,
  /// newest first, in its sample's place, each an item of its own that the limit counts; a page
  /// can end inside a series, and its cursor says where (`<start>_<id>_<index>`).
  public func samples(
    type: String, range: ToolRange, date: String? = nil, timeZone: String? = nil,
    cursor: String? = nil, limit: Int? = nil, seriesValues: Bool? = nil, _ db: Database
  ) throws -> HealthSamplesResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    let type = try Self.dataType(type)
    switch Self.samplesKind(type.kind) {
    case .listed: break
    case .elsewhere(let tool):
      throw HealthToolError("samples doesn't list \(type.name) (\(type.id)): use \(tool).")
    case .unread:
      throw HealthToolError(
        "samples doesn't list \(type.name) (\(type.id)), and no other tool reads that kind yet.")
    }
    let limit = limit ?? Self.samplesDefaultLimit
    guard (1...Self.samplesLimit).contains(limit) else {
      throw HealthToolError("The limit must be from 1 to \(Self.samplesLimit).")
    }
    let period = try ToolPeriod(range, date: date, now: now, time: time)
    let after = try cursor.map(Self.sampleCursor)
    let listsValues = seriesValues == true && type.kind == .quantity
    // A page that ended inside a series' values goes on with the rest of them.
    let within = listsValues ? after?.index : nil
    // One more than asked for, to know whether there's another page: each sample is at least
    // one item.
    let page: [ListedSample]
    var values: [String: [HealthCorrelatedValue]] = [:]
    var series: [String: HealthQuantitySeries] = [:]
    if type.kind == .correlation {
      let correlations = try HealthDatabase.correlationPage(
        of: type.id, in: period.interval, after: after?.sample, limit: limit + 1, db)
      page = correlations.map(ListedSample.init)
      let members = try HealthDatabase.correlatedSamples(
        of: correlations.prefix(limit).map(\.id), db)
      for member in members {
        guard let correlation = member.correlationID else { continue }
        values[correlation, default: []].append(
          HealthCorrelatedValue(type: member.type, value: member.value, unit: member.unit))
      }
    } else {
      page = try HealthDatabase.samplePage(
        of: type.id, in: period.interval, after: after?.sample, includingCursor: within != nil,
        limit: limit + (within != nil ? 2 : 1), db
      ).map(ListedSample.init)
      if type.kind == .quantity {
        series = try HealthDatabase.quantitySeries(ofSamples: page.map(\.id), db)
      }
    }
    // Each sample's items: itself, or a series' values, newest first.
    var listed: [ListedItem] = []
    pages: for sample in page {
      let isCursor = within != nil && sample.id == after?.sample.id
      let quantitySeries = series[sample.id]
      if listsValues, let quantitySeries,
        let seriesValues = QuantitySeriesValues(
          times: quantitySeries.times, durations: quantitySeries.durations,
          values: quantitySeries.values)
      {
        let last = isCursor ? (within ?? 0) - 1 : seriesValues.values.count - 1
        for index in stride(from: min(last, seriesValues.values.count - 1), through: 0, by: -1) {
          guard listed.count <= limit else { break pages }
          let interval = seriesValues.interval(at: index, sampleStart: sample.startDate)
          listed.append(
            ListedItem(
              sample: sample, start: interval.start, end: interval.end,
              value: seriesValues.values[index],
              series: HealthSampleSeries(count: quantitySeries.count, index: index),
              cursor: index > 0
                ? "\(sample.startDate)_\(sample.id)_\(index)" : "\(sample.startDate)_\(sample.id)"))
        }
      } else if !isCursor {
        guard listed.count <= limit else { break }
        listed.append(
          ListedItem(
            sample: sample, start: sample.startDate, end: sample.endDate, value: sample.value,
            series: quantitySeries.map { series in
              HealthSampleSeries(
                count: series.count, minimum: series.minimum, maximum: series.maximum,
                mostRecent: series.mostRecent,
                mostRecentStart: series.mostRecentStartDate.map {
                  time.localTime(Date(unixMilliseconds: $0))
                },
                mostRecentEnd: series.mostRecentEndDate.map {
                  time.localTime(Date(unixMilliseconds: $0))
                })
            },
            cursor: "\(sample.startDate)_\(sample.id)"))
      }
    }
    let items = listed.prefix(limit)
    var sources = SampleSources()
    let samples = items.map { item in
      let sample = item.sample
      let metadata = SampleDetails.object(sample.metadata)
      var details = SampleDetails.details(metadata, time: time)
      if type.kind == .correlation { details.values = values[sample.id] ?? [] }
      return HealthSampleItem(
        id: sample.id, start: time.localTime(Date(unixMilliseconds: item.start)),
        end: time.localTime(Date(unixMilliseconds: item.end)), value: item.value,
        unit: sample.unit, categoryValue: sample.categoryValue, source: sample.stored.sourceName,
        sourceIndex: sources.index(of: sample.stored, metadata: metadata), series: item.series,
        details: details)
    }
    return HealthSamplesResult(
      timeZone: time.name, range: range.rawValue, start: time.localTime(period.start),
      end: time.localTime(period.end), type: type.id, samples: samples, sources: sources.sources,
      nextCursor: listed.count > limit ? items.last?.cursor : nil)
  }

  /// One of `samples`' items: a sample, or one of a series' values (851-4171), with the cursor
  /// of a page ending with it.
  fileprivate struct ListedItem {
    var sample: ListedSample
    var start: Int
    var end: Int
    var value: Double?
    var series: HealthSampleSeries?
    var cursor: String
  }

  /// Whether `samples` lists a kind, or which tool reads it instead, or that none does yet (their
  /// tools come under 851-4156), as the server's `samplesElsewhere`.
  enum SamplesKind: Equatable {
    case listed
    case elsewhere(String)
    case unread
  }

  static func samplesKind(_ kind: HealthDataType.Kind) -> SamplesKind {
    switch kind {
    case .quantity, .category, .correlation: .listed
    case .workout: .elsewhere("workouts")
    case .workoutRoute: .elsewhere("workout_routes")
    case .medication, .medicationDoseEvent: .elsewhere("medications")
    case .characteristic, .visionPrescription: .elsewhere("health_details")
    case .activitySummary, .heartbeatSeries, .electrocardiogram, .audiogram,
      .stateOfMind, .scoredAssessment, .document:
      .unread
    }
  }

  /// A sample or a correlation, as `samples` lists them.
  fileprivate struct ListedSample {
    var id: String
    var startDate: Int
    var endDate: Int
    var value: Double?
    var unit: String?
    var categoryValue: Int?
    var stored: SampleDetails.Stored
    /// JSON, or nil.
    var metadata: String?

    var start: Date { Date(unixMilliseconds: startDate) }
    var end: Date { Date(unixMilliseconds: endDate) }
  }

  /// A page's cursor: its last sample's start and ID, and, if it ended inside a series' values,
  /// the index of the last one listed (851-4171).
  private static func sampleCursor(_ text: String) throws -> (sample: SampleCursor, index: Int?) {
    let parts = text.split(separator: "_", omittingEmptySubsequences: false)
    guard (2...3).contains(parts.count), let start = Int(parts[0]), !parts[1].isEmpty else {
      throw HealthToolError("Invalid cursor: \(text). Pass the previous page's nextCursor.")
    }
    var index: Int?
    if parts.count == 3 {
      // At most 9 digits (a series has at most 20,000 values), as on the server.
      guard parts[2].count <= 9, let value = Int(parts[2]), value > 0, String(value) == parts[2]
      else {
        throw HealthToolError("Invalid cursor: \(text). Pass the previous page's nextCursor.")
      }
      index = value
    }
    return (SampleCursor(startDate: start, id: String(parts[1])), index)
  }

  // MARK: - workouts

  /// Workouts that started in the period, newest first, at most `workoutsLimit`, with the
  /// period's count and total time.
  public func workouts(
    range: ToolRange, date: String? = nil, timeZone: String? = nil, _ db: Database
  ) throws -> HealthWorkoutsResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    let period = try ToolPeriod(range, date: date, now: now, time: time)
    let totals = try HealthDatabase.workoutTotals(in: period.interval, db)
    let workouts = try HealthDatabase.workouts(
      in: period.interval, limit: Self.workoutsLimit, db)
    let withRoutes = try HealthDatabase.workoutsWithRoutes(workouts, db)
    return HealthWorkoutsResult(
      timeZone: time.name, range: range.rawValue, start: time.localTime(period.start),
      end: time.localTime(period.end), count: totals.count, duration: totals.duration,
      workouts: workouts.map { Self.readWorkout($0, withRoutes: withRoutes, time: time).item })
  }

  /// What `workouts` says of a workout, with the statistics, metadata and activities it read,
  /// which `workout` adds to.
  private static func readWorkout(
    _ workout: HealthWorkout, withRoutes: Set<String>, time: ToolTime
  ) -> (
    item: HealthWorkoutItem, statistics: [String: WorkoutStatistic], metadata: WorkoutMetadata,
    activities: [WorkoutActivityRecord]
  ) {
    let statistics = workout.decodedStatistics
    let metadata = workout.decodedMetadata
    let activities = workout.decodedActivities
    let location = HealthWorkout.location(metadata: metadata, activities: activities)
    let item = HealthWorkoutItem(
      id: workout.id, activityType: workout.activityType,
      activity: HealthCatalog.workoutActivityName(workout.activityType),
      name: metadata.name,
      start: time.localTime(Date(unixMilliseconds: workout.startDate)),
      end: time.localTime(Date(unixMilliseconds: workout.endDate)),
      duration: workout.duration,
      activeEnergy: statistics[HealthWorkout.activeEnergyType]?.sum,
      distance: HealthWorkout.distance(in: statistics),
      averageHeartRate: statistics[HealthWorkout.heartRateType]?.average,
      elevationAscended: metadata.elevationAscended, indoor: location.indoor,
      swimmingLocation: location.swimmingLocation,
      hasRoute: withRoutes.contains(workout.id), source: workout.sourceName,
      activities: activities.count < 2
        ? []
        : activities.map { activity in
          HealthWorkoutActivityItem(
            activityType: activity.activityType,
            activity: HealthCatalog.workoutActivityName(activity.activityType),
            start: time.localTime(Date(timeIntervalSince1970: activity.startDate / 1000)),
            end: activity.endDate.map {
              time.localTime(Date(timeIntervalSince1970: $0 / 1000))
            },
            duration: activity.duration, indoor: activity.indoor,
            swimmingLocation: activity.swimmingLocation)
        })
    return (item, statistics, metadata, activities)
  }

  // MARK: - workout

  /// The most pauses, laps or segments `workout` lists of each.
  public static let workoutEventsLimit = 300

  /// One workout, by its ID, with everything `workouts` says of it and the rest of what the
  /// iPhone uploads (851-4165).
  public func workout(id: String, timeZone: String? = nil, _ db: Database) throws
    -> HealthWorkoutResult
  {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    guard let workout = try HealthWorkout.where({ $0.id.eq(id) }).fetchOne(db) else {
      throw HealthToolError("No workout with ID \(id). workouts lists them, with their IDs.")
    }
    let (item, statistics, metadata, activities) = Self.readWorkout(
      workout, withRoutes: try HealthDatabase.workoutsWithRoutes([workout], db), time: time)
    let events = workout.decodedEventRecords
    let pauses = HealthWorkout.pauses(events.map(\.event), end: workout.endDate)
    func local(_ milliseconds: Int) -> String {
      time.localTime(Date(unixMilliseconds: milliseconds))
    }
    func intervals(_ type: Int) -> [HealthWorkoutInterval] {
      HealthWorkout.stableSorted(events.filter { $0.event.type == type }, by: \.event.startDate)
        .map { record in
          HealthWorkoutInterval(
            start: local(record.event.startDate), end: local(record.event.endDate),
            duration: Double(record.event.endDate - record.event.startDate) / 1000,
            strokeStyle: record.metadata.strokeStyle, swolf: record.metadata.swolf,
            lapLength: record.metadata.lapLength, averageSpeed: record.metadata.averageSpeed,
            maximumSpeed: record.metadata.maximumSpeed)
        }
    }
    let laps = intervals(WorkoutEvent.lap)
    let segments = intervals(WorkoutEvent.segment)
    let limit = Self.workoutEventsLimit
    return HealthWorkoutResult(
      timeZone: time.name,
      workout: HealthWorkoutDetail(
        id: item.id, activityType: item.activityType, activity: item.activity, name: item.name,
        start: item.start, end: item.end, duration: item.duration,
        activeEnergy: item.activeEnergy, distance: item.distance,
        averageHeartRate: item.averageHeartRate, elevationAscended: item.elevationAscended,
        indoor: item.indoor, swimmingLocation: item.swimmingLocation, hasRoute: item.hasRoute,
        source: item.source, elevationDescended: metadata.elevationDescended,
        averageSpeed: metadata.averageSpeed, maximumSpeed: metadata.maximumSpeed,
        averageMETs: metadata.averageMETs, lapLength: metadata.lapLength, swolf: metadata.swolf,
        weatherCondition: metadata.weatherCondition,
        weatherTemperature: metadata.weatherTemperature,
        weatherHumidity: metadata.weatherHumidity,
        statistics: Self.statisticsList(statistics),
        pauseCount: pauses.count,
        pauses: pauses.prefix(limit).map {
          HealthWorkoutPause(
            start: local($0.start), end: local($0.end), duration: Double($0.end - $0.start) / 1000)
        },
        lapCount: laps.count, laps: Array(laps.prefix(limit)),
        segmentCount: segments.count, segments: Array(segments.prefix(limit)),
        activities: zip(item.activities, activities).map { leg, activity in
          HealthWorkoutLeg(
            activityType: leg.activityType, activity: leg.activity, start: leg.start,
            end: leg.end, duration: leg.duration, indoor: leg.indoor,
            swimmingLocation: leg.swimmingLocation,
            elevationAscended: activity.metadata.elevationAscended,
            elevationDescended: activity.metadata.elevationDescended,
            averageSpeed: activity.metadata.averageSpeed,
            maximumSpeed: activity.metadata.maximumSpeed,
            averageMETs: activity.metadata.averageMETs, lapLength: activity.metadata.lapLength,
            swolf: activity.metadata.swolf, statistics: Self.statisticsList(activity.statistics))
        }))
  }

  /// Statistics as `workout` lists them: by type ID.
  private static func statisticsList(_ statistics: [String: WorkoutStatistic])
    -> [HealthWorkoutStatistic]
  {
    statistics.sorted { $0.key < $1.key }.map { type, statistic in
      HealthWorkoutStatistic(
        type: type, name: HealthCatalog.type(id: type)?.name, unit: statistic.unit,
        sum: statistic.sum, average: statistic.average, minimum: statistic.minimum,
        maximum: statistic.maximum, mostRecent: statistic.mostRecent)
    }
  }

  // MARK: - sleep

  /// Each night that ends in the period, oldest first, as the app's Sleep page has them.
  public func sleep(
    range: ToolRange, date: String? = nil, timeZone: String? = nil, _ db: Database
  ) throws -> HealthSleepResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
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
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
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
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
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
    // Characteristics have no dates: those set, not Not Set (`null`).
    let characteristics = Set(
      try HealthDatabase.characteristics(db).filter { $0.value != "null" }.map(\.id))
    func hasData(_ type: HealthDataType) -> Bool {
      dates[type.id] != nil || (type.kind == .medication && hasMedications)
        || characteristics.contains(type.id)
    }
    let types = HealthCatalog.all
      .filter { matches("\($0.name) \($0.category?.name ?? "") \(HealthCatalog.shortID($0.id))") }
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
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
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
    guard let match = HealthCatalog.type(named: name) else {
      throw HealthToolError(
        "Unknown type: \(name). Use a HealthKit identifier, e.g. "
          + "HKQuantityTypeIdentifierStepCount; search finds them.")
    }
    return match
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

extension HealthTools.ListedSample {
  init(_ sample: HealthSample) {
    self.init(
      id: sample.id, startDate: sample.startDate, endDate: sample.endDate, value: sample.value,
      unit: sample.unit, categoryValue: sample.categoryValue,
      stored: SampleDetails.Stored(
        sourceName: sample.sourceName, sourceBundleID: sample.sourceBundleID,
        sourceRevision: sample.sourceRevision, device: sample.device),
      metadata: sample.metadata)
  }

  init(_ correlation: HealthCorrelation) {
    self.init(
      id: correlation.id, startDate: correlation.startDate, endDate: correlation.endDate,
      value: nil, unit: nil, categoryValue: nil,
      stored: SampleDetails.Stored(
        sourceName: correlation.sourceName, sourceBundleID: correlation.sourceBundleID,
        sourceRevision: correlation.sourceRevision, device: correlation.device),
      metadata: correlation.metadata)
  }
}
