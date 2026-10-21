import Foundation
import HealthCatalog
import HealthDatabase
import SQLiteData
import Testing

@testable import HealthTools

// Synthetic data only (AGENTS.md).
private let device = "dev_000000000000000000000000ph"
private let otherDevice = "dev_000000000000000000000000ot"
private let steps = "HKQuantityTypeIdentifierStepCount"
private let heartRate = "HKQuantityTypeIdentifierHeartRate"
/// Tuesday, October 20, 2026, 15:00 UTC (16:00 in London).
private let now = Date(timeIntervalSince1970: 1_792_508_400)
private let tools = HealthTools(now: now)

/// `hours` after midnight UTC on October `day`, 2026.
private func utc(_ hours: Double, day: Int = 20) -> Date {
  Date(timeIntervalSince1970: 1_792_454_400 + Double(day - 20) * 86_400 + hours * 3600)
}

private func sample(
  _ type: String, at start: Date, minutes: Double = 1, value: Double? = nil,
  unit: String? = "count", category: Int? = nil, source: String = "com.example",
  id: String = UUID().uuidString.lowercased()
) -> HealthSample {
  HealthSample(
    id: id, type: type, startDate: start.unixMilliseconds,
    endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, value: value,
    unit: category == nil ? unit : nil, categoryValue: category, sourceName: "Synthetic Watch",
    sourceBundleID: source)
}

private func statistic(_ type: String, at start: Date, sum: Double, device: String = device)
  -> HealthStatistic
{
  HealthStatistic(
    id: "\(device)/\(type)@\(start.unixMilliseconds)", device: device, type: type,
    bucketStart: start.unixMilliseconds, sum: sum, unit: "count")
}

private func utcCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}

@Suite
struct HealthToolsTests {
  let database: any DatabaseWriter

  init() throws {
    database = try HealthDatabase.make()
    try database.write { db in
      try HealthStatisticsDevice.insert {
        HealthStatisticsDevice(
          id: device, device: device, pairedWithWatch: true,
          reportedAt: utc(14).unixMilliseconds)
        HealthStatisticsDevice(
          id: otherDevice, device: otherDevice, pairedWithWatch: false,
          reportedAt: utc(14.5).unixMilliseconds)
      }
      .execute(db)
    }
  }

  // MARK: - Time

  @Test
  func timesAreLocalWithTheirOffsetAndDaysExist() throws {
    let london = try ToolTime(timeZone: "Europe/London")
    #expect(london.localTime(utc(7.25)) == "2026-10-20T08:15:00+01:00")
    #expect(london.localDate(utc(23.5)) == "2026-10-21")
    // Rounded down to the second.
    #expect(
      try ToolTime(timeZone: "UTC").localTime(utc(7.25).addingTimeInterval(0.9))
        == "2026-10-20T07:15:00+00:00")
    // Aliases are echoed as given.
    #expect(try ToolTime(timeZone: "US/Pacific").name == "US/Pacific")

    #expect(
      throws: HealthToolError("Unknown time zone: europe/london. Did you mean Europe/London?")
    ) {
      try ToolTime(timeZone: "europe/london")
    }
    #expect(
      throws: HealthToolError("Unknown time zone: +01:00. Use an IANA name, e.g. Europe/London.")
    ) {
      try ToolTime(timeZone: "+01:00")
    }
    #expect(throws: HealthToolError.self) { try ToolTime(timeZone: "Mars/Olympus_Mons") }
    #expect(throws: HealthToolError.self) { try london.day("2026-02-31") }
    #expect(throws: HealthToolError.self) { try london.day("20 October") }
  }

  @Test
  func rangesEndOnTheirDayInBuckets() throws {
    let time = try ToolTime(timeZone: "UTC")
    func period(_ range: ToolRange, _ date: String? = nil) throws -> ToolPeriod {
      try ToolPeriod(range, date: date, now: now, time: time)
    }
    let day = try period(.day)
    #expect(day.start == utc(0) && day.end == utc(0, day: 21) && day.buckets.count == 24)
    let week = try period(.week)
    #expect(week.start == utc(0, day: 14) && week.buckets.count == 7)
    #expect(try period(.month).buckets.count == 30)
    let sixMonths = try period(.sixMonths)
    #expect(sixMonths.buckets.count == 26 && sixMonths.start == utc(0, day: 21 - 182))
    #expect(sixMonths.buckets[1] == sixMonths.start.addingTimeInterval(7 * 86_400))
    let year = try period(.year, "2026-03-15")
    #expect(time.localDate(year.start) == "2025-04-01" && year.buckets.count == 12)
    #expect(time.localDate(year.end) == "2026-03-16")

    // London's last Sunday of October has 25 hours.
    let london = try ToolTime(timeZone: "Europe/London")
    let longDay = try ToolPeriod(.day, date: "2026-10-25", now: now, time: london)
    #expect(longDay.buckets.count == 25)
  }

  // MARK: - summary

  @Test
  func summaryHasTodaysAndTheWeeksTotalsAndTheLatestSample() throws {
    try database.write { db in
      try HealthStatistic.insert {
        statistic(steps, at: utc(9), sum: 1000)
        statistic(steps, at: utc(9.5), sum: 2200)
        statistic(steps, at: utc(12, day: 16), sum: 5300)
        // Before the 7 days, and from an iPhone that isn't the source.
        statistic(steps, at: utc(12, day: 13), sum: 999)
        statistic(steps, at: utc(10), sum: 9999, device: otherDevice)
        // An empty bucket ahead of now doesn't count.
        statistic(steps, at: utc(20), sum: 0)
      }
      .execute(db)
      try HealthSample.insert {
        sample(steps, at: utc(14.1), minutes: 5, value: 412)
        // Logged ahead of now.
        sample(steps, at: utc(18), value: 5)
        sample(heartRate, at: utc(14.5), value: 72, unit: "count/min")
      }
      .execute(db)
      try HealthWorkout.insert {
        workout("w1", at: utc(7), duration: 1800)
        workout("w2", at: utc(7, day: 15), duration: 2400)
        // Before the 7 days, and later today.
        workout("w3", at: utc(7, day: 13), duration: 600)
        workout("w4", at: utc(18), duration: 600)
      }
      .execute(db)
    }
    let summary = try database.read { try tools.summary(timeZone: "UTC", $0) }
    #expect(summary.timeZone == "UTC" && summary.date == "2026-10-20" && !summary.pinned)
    #expect(summary.metrics.map(\.type) == HealthTools.summaryDefaultTypes)
    #expect(
      summary.metrics[0]
        == HealthSummaryMetric(
          type: steps, unit: "count",
          latest: .init(
            start: "2026-10-20T14:06:00+00:00", end: "2026-10-20T14:11:00+00:00", value: 412,
            categoryValue: nil),
          today: 3200, last7Days: 8500))
    #expect(summary.metrics[1].latest?.value == 72 && summary.metrics[1].today == nil)
    #expect(summary.metrics[5] == HealthSummaryMetric(type: "HKQuantityTypeIdentifierBodyMass"))
    #expect(summary.workouts == .init(count: 2, duration: 4200))
  }

  @Test
  func summaryShowsThePinsInTheirOrder() throws {
    try database.write { db in
      try HealthPin.insert {
        HealthPin(id: heartRate, position: 1)
        HealthPin(id: steps, position: 0)
      }
      .execute(db)
    }
    let summary = try database.read { try tools.summary(timeZone: "UTC", $0) }
    #expect(summary.pinned && summary.metrics.map(\.type) == [steps, heartRate])
  }

  // MARK: - metric

  @Test
  func aCumulativeWeekMatchesTheAppsChart() throws {
    try database.write { db in
      try HealthStatistic.insert {
        statistic(steps, at: utc(9, day: 14), sum: 4000)
        statistic(steps, at: utc(9, day: 15), sum: 1000)
        statistic(steps, at: utc(21, day: 15), sum: 500)
        statistic(steps, at: utc(9, day: 17), sum: 7000)
        statistic(steps, at: utc(9, day: 13), sum: 999)
      }
      .execute(db)
      // Past the last bucket, the samples' own total, as in the app.
      try HealthSample.insert { sample(steps, at: utc(10), value: 300) }.execute(db)
    }
    let metric = try database.read {
      try tools.metric(type: "Steps", range: .week, timeZone: "UTC", $0)
    }
    #expect(metric.type == steps && metric.unit == "count" && metric.statistic == "sum")
    #expect(
      metric.start == "2026-10-14T00:00:00+00:00" && metric.end == "2026-10-21T00:00:00+00:00")
    #expect(metric.value == 12_800)
    #expect(metric.buckets.map(\.value) == [4000, 1500, nil, 7000, nil, nil, 300])
    #expect(metric.buckets.first?.start == "2026-10-14T00:00:00+00:00")

    // The app's previous week (Sunday the 11th to Saturday the 17th, by the day) has the same
    // days.
    let chart = try database.read {
      try HealthDatabase.metricChart(
        of: HealthCatalog.type(id: steps)!, range: .week, offset: -1, now: now,
        calendar: utcCalendar(), $0)
    }
    // The 13th is before the tool's 7 days.
    #expect(chart.points.map(\.value) == [999, 4000, 1500, 7000])
    #expect(metric.buckets.prefix(4).compactMap(\.value) == chart.points.dropFirst().map(\.value))

    let average = try database.read {
      try tools.metric(type: steps, range: .week, statistic: .average, timeZone: "UTC", $0)
    }
    // Of the 4 days with data.
    #expect(average.value == 3200 && average.buckets[1].value == 1500)
    let maximum = try database.read {
      try tools.metric(type: "stepcount", range: .month, statistic: .maximum, timeZone: "UTC", $0)
    }
    #expect(maximum.value == 7000 && maximum.buckets.count == 30)
  }

  @Test
  func aCumulativeDayIsHourlyTotals() throws {
    try database.write { db in
      try HealthStatistic.insert {
        statistic(steps, at: utc(9), sum: 100)
        statistic(steps, at: utc(9.5), sum: 50)
        statistic(steps, at: utc(14), sum: 200)
      }
      .execute(db)
    }
    let metric = try database.read {
      try tools.metric(type: steps, range: .day, statistic: .average, timeZone: "UTC", $0)
    }
    // The average hour with steps.
    #expect(metric.value == 175)
    #expect(metric.buckets.count == 24 && metric.buckets[9].value == 150)
    let total = try database.read {
      try tools.metric(type: steps, range: .day, timeZone: "UTC", $0)
    }
    #expect(total.value == 350)
    #expect(metric.buckets[14].start == "2026-10-20T14:00:00+00:00")
  }

  @Test
  func aDiscreteTypeIsWeightedAsTheAppWeighsIt() throws {
    try database.write { db in
      try HealthSample.insert {
        // Heart rate is time-weighted: 60 for 10 minutes, then 90 for 1.
        sample(heartRate, at: utc(9), value: 60, unit: "count/min")
        sample(heartRate, at: utc(9 + 10.0 / 60), value: 90, unit: "count/min")
        sample(heartRate, at: utc(9, day: 18), value: 70, unit: "count/min")
      }
      .execute(db)
    }
    let metric = try database.read {
      try tools.metric(type: "heart rate", range: .week, timeZone: "UTC", $0)
    }
    let days = try database.read {
      try HealthDatabase.discreteStatistics(
        of: heartRate, in: utc(0, day: 14)..<utc(0, day: 21), by: .day, calendar: utcCalendar(),
        $0)
    }
    #expect(metric.statistic == "average" && metric.unit == "count/min")
    #expect(metric.buckets[6].value == days.last?.average)
    #expect(metric.buckets[4].value == 70)
    #expect(abs(metric.buckets[6].value! - (60 * 600 + 90 * 60) / 660) < 1e-9)
    let maximum = try database.read {
      try tools.metric(type: heartRate, range: .week, statistic: .maximum, timeZone: "UTC", $0)
    }
    #expect(maximum.value == 90)

    #expect(throws: HealthToolError.self) {
      try database.read {
        try tools.metric(type: heartRate, range: .week, statistic: .sum, $0)
      }
    }
    #expect(throws: HealthToolError.self) {
      try database.read { try tools.metric(type: "Sleep", range: .week, $0) }
    }
    #expect(throws: HealthToolError.self) {
      try database.read { try tools.metric(type: "Nope", range: .week, $0) }
    }
  }

  // MARK: - samples

  @Test
  func samplesComeNewestFirstAPageAtATime() throws {
    try database.write { db in
      try HealthSample.insert {
        sample(heartRate, at: utc(8), value: 60, id: "a")
        sample(heartRate, at: utc(9), value: 61, id: "b")
        sample(heartRate, at: utc(9), value: 62, id: "c")
        sample(heartRate, at: utc(10), value: 63, id: "d")
        // Another day.
        sample(heartRate, at: utc(10, day: 19), value: 64, id: "e")
      }
      .execute(db)
    }
    let first = try database.read {
      try tools.samples(type: heartRate, range: .day, timeZone: "UTC", limit: 2, $0)
    }
    #expect(first.samples.map(\.id) == ["d", "c"])
    #expect(first.samples[0].source == "Synthetic Watch" && first.samples[0].value == 63)
    let cursor = try #require(first.nextCursor)
    let second = try database.read {
      try tools.samples(
        type: heartRate, range: .day, timeZone: "UTC", cursor: cursor, limit: 2, $0)
    }
    #expect(second.samples.map(\.id) == ["b", "a"] && second.nextCursor == nil)

    #expect(throws: HealthToolError.self) {
      try database.read { try tools.samples(type: heartRate, range: .day, limit: 501, $0) }
    }
    #expect(throws: HealthToolError.self) {
      try database.read { try tools.samples(type: heartRate, range: .day, cursor: "x", $0) }
    }
  }

  // MARK: - workouts, sleep

  @Test
  func workoutsListTheirActivityAndFigures() throws {
    try database.write { db in
      try HealthWorkout.insert {
        workout(
          "w1", at: utc(7), duration: 1800,
          statistics: #"""
            {"HKQuantityTypeIdentifierActiveEnergyBurned":{"unit":"kcal","sum":310},\#
            "HKQuantityTypeIdentifierDistanceWalkingRunning":{"unit":"m","sum":5200},\#
            "HKQuantityTypeIdentifierHeartRate":{"unit":"count/min","average":148}}
            """#)
        workout("w2", at: utc(7, day: 15), duration: 2400, activityType: 9999)
      }
      .execute(db)
    }
    let workouts = try database.read { try tools.workouts(range: .week, timeZone: "UTC", $0) }
    #expect(workouts.count == 2 && workouts.duration == 4200)
    #expect(
      workouts.workouts[0]
        == HealthWorkoutItem(
          id: "w1", activityType: 37, activity: "Running", start: "2026-10-20T07:00:00+00:00",
          end: "2026-10-20T07:30:00+00:00", duration: 1800, activeEnergy: 310, distance: 5200,
          averageHeartRate: 148, source: "Synthetic Watch"))
    #expect(workouts.workouts[1].activity == "Workout" && workouts.workouts[1].distance == nil)
  }

  @Test
  func sleepIsPerNightWithItsStages() throws {
    let sleep = HealthDatabase.sleepType
    try database.write { db in
      try HealthSample.insert {
        // The night ending on the 20th: in bed 22:30 to 06:30, asleep from 23:00.
        sample(sleep, at: utc(22.5, day: 19), minutes: 480, category: 0)
        sample(sleep, at: utc(23, day: 19), minutes: 180, category: 3)
        sample(sleep, at: utc(2, day: 20), minutes: 60, category: 4)
        sample(sleep, at: utc(3, day: 20), minutes: 15, category: 2)
        sample(sleep, at: utc(3.25, day: 20), minutes: 120, category: 5)
      }
      .execute(db)
    }
    let result = try database.read { try tools.sleep(range: .week, timeZone: "UTC", $0) }
    #expect(
      result.nights == [
        HealthSleepNight(
          date: "2026-10-20", start: "2026-10-19T23:00:00+00:00",
          end: "2026-10-20T05:15:00+00:00", inBed: 8 * 3600, asleep: 6 * 3600, awake: 900,
          core: 3 * 3600, deep: 3600, rem: 2 * 3600, unspecified: 0)
      ])
  }

  // MARK: - medications, details

  @Test
  func medicationsHaveTheirAdherenceAndLastDose() throws {
    try database.write { db in
      try HealthMedication.insert {
        HealthMedication(
          id: "m1", name: "Synthetic Tablet", nickname: "Morning pill", generalForm: "tablet",
          hasSchedule: true)
        HealthMedication(id: "m2", name: "Synthetic Cream", generalForm: "cream", isArchived: true)
      }
      .execute(db)
      try HealthMedicationDose.insert {
        dose("d1", due: utc(8), status: 4)
        dose("d2", due: utc(8, day: 19), status: 5)
        dose("d3", due: utc(8, day: 1), status: 4)
      }
      .execute(db)
    }
    let result = try database.read { try tools.medications(timeZone: "UTC", $0) }
    #expect(result.medications.map(\.id) == ["m1", "m2"])
    let first = result.medications[0]
    #expect(first.name == "Morning pill" && first.healthName == "Synthetic Tablet")
    #expect(first.form == "tablet" && first.scheduled && !first.archived)
    #expect(first.last7Days == .init(scheduled: 2, taken: 1, asNeeded: 0))
    #expect(first.last30Days == .init(scheduled: 3, taken: 2, asNeeded: 0))
    #expect(first.lastTaken == "2026-10-20T08:00:00+00:00")
    #expect(result.medications[1].archived && result.medications[1].lastTaken == nil)
  }

  @Test
  func detailsAreTheCharacteristicsAndPrescriptions() throws {
    try database.write { db in
      try HealthCharacteristic.insert {
        HealthCharacteristic(
          id: "HKCharacteristicTypeIdentifierDateOfBirth",
          value: #"{"year":1990,"month":11,"day":2}"#)
        HealthCharacteristic(id: "HKCharacteristicTypeIdentifierBloodType", value: #""abNegative""#)
        HealthCharacteristic(id: "HKCharacteristicTypeIdentifierBiologicalSex", value: #""female""#)
        HealthCharacteristic(
          id: "HKCharacteristicTypeIdentifierWheelchairUse", value: #""no""#)
      }
      .execute(db)
      try HealthVisionPrescription.insert {
        HealthVisionPrescription(
          id: "v1", startDate: utc(12, day: 2).unixMilliseconds,
          endDate: utc(12, day: 2).unixMilliseconds, prescriptionType: 1,
          rightEye: #"{"sphere":-1.25,"cylinder":-0.5,"axis":90}"#, sourceName: "Synthetic",
          sourceBundleID: "com.example")
      }
      .execute(db)
    }
    let details = try database.read { try tools.healthDetails(timeZone: "UTC", $0) }
    #expect(details.dateOfBirth == "1990-11-02" && details.age == 35)
    #expect(details.sex == "female" && details.bloodType == "AB-")
    #expect(details.fitzpatrickSkinType == nil && details.wheelchairUse == false)
    #expect(
      details.visionPrescriptions == [
        HealthVisionPrescriptionItem(
          id: "v1", kind: "glasses", issued: "2026-10-02", expires: nil, brand: nil,
          rightEye: HealthLens(sphere: -1.25, cylinder: -0.5, axis: 90, addPower: nil),
          leftEye: nil)
      ])
    // Set characteristics are data, though they have no dates.
    let search = try database.read { try tools.search(query: "blood type", $0) }
    #expect(search.types.map(\.hasData) == [true])
  }

  // MARK: - types, search, sync status

  @Test
  func typesSearchAndSyncStatus() throws {
    try database.write { db in
      try HealthSample.insert {
        sample(steps, at: utc(9, day: 1), value: 10)
        sample(steps, at: utc(9), value: 10)
        sample(heartRate, at: utc(10), value: 70, unit: "count/min")
        // Logged ahead.
        sample(heartRate, at: utc(20), value: 70, unit: "count/min")
      }
      .execute(db)
      try HealthWorkout.insert { workout("w1", at: utc(7), duration: 60) }.execute(db)
    }
    let types = try database.read { try tools.listTypes(timeZone: "UTC", $0) }
    #expect(types.types.map(\.name) == ["Steps", "Workouts", "Heart Rate"])
    #expect(
      types.types[0]
        == HealthTypeInfo(
          type: steps, name: "Steps", category: "Activity", kind: "quantity", unit: "count",
          cumulative: true, first: "2026-10-01T09:00:00+00:00",
          last: "2026-10-20T09:00:00+00:00"))
    #expect(types.types[1].kind == "workout" && types.types[1].unit == nil)

    let search = try database.read { try tools.search(query: "heart RATE", $0) }
    #expect(
      search.types.first
        == HealthSearchType(
          type: heartRate, name: "Heart Rate", category: "Heart", hasData: true))
    #expect(search.types.dropFirst().allSatisfy { !$0.hasData })
    let vo2 = try database.read { try tools.search(query: "vo2", $0) }
    #expect(vo2.types.map(\.type) == ["HKQuantityTypeIdentifierVO2Max"])
    #expect(throws: HealthToolError.self) { try database.read { try tools.search(query: " ", $0) } }

    let status = try database.read { try tools.syncStatus(timeZone: "UTC", $0) }
    #expect(status.latestSample == "2026-10-20T10:00:00+00:00")
    #expect(
      status.iPhones == [
        HealthSyncIPhone(
          device: otherDevice, pairedWithWatch: false, lastReported: "2026-10-20T14:30:00+00:00",
          statisticsSource: false),
        HealthSyncIPhone(
          device: device, pairedWithWatch: true, lastReported: "2026-10-20T14:00:00+00:00",
          statisticsSource: true),
      ])
  }

  // MARK: - JSON

  @Test
  func jsonHasEveryFieldNullsIncluded() throws {
    let summary = try database.read { try tools.summary(timeZone: "UTC", $0) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(summary.metrics[0]), as: UTF8.self)
    #expect(
      json
        == #"{"last7Days":null,"latest":null,"today":null,"type":"HKQuantityTypeIdentifierStepCount","unit":null}"#
    )
    let decoded = try JSONDecoder().decode(
      HealthSummaryResult.self, from: try encoder.encode(summary))
    #expect(decoded == summary)
  }
}

private func workout(
  _ id: String, at start: Date, duration: Double, activityType: Int = 37,
  statistics: String = "{}"
) -> HealthWorkout {
  HealthWorkout(
    id: id, activityType: activityType, startDate: start.unixMilliseconds,
    endDate: start.addingTimeInterval(duration).unixMilliseconds, duration: duration,
    activities: "[]", events: "[]", statistics: statistics, sourceName: "Synthetic Watch",
    sourceBundleID: "com.example")
}

private func dose(_ id: String, due: Date, status: Int) -> HealthMedicationDose {
  HealthMedicationDose(
    id: id, startDate: due.unixMilliseconds, endDate: due.unixMilliseconds, medication: "m1",
    logStatus: status, scheduleType: 2, scheduledDate: due.unixMilliseconds,
    scheduledDoseQuantity: 1, doseQuantity: status == 4 ? 1 : nil, unit: "count",
    sourceName: "Synthetic", sourceBundleID: "com.example")
}
