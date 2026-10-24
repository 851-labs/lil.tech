import Foundation
import Testing

@testable import HealthCards

// Nights, sleep windows and workout windows in the engine's core (docs/decisions/cards.md, Event
// windows, 851-3196), on synthetic sleep, workouts and readings in London.

private let watch = "com.apple.health.watch"
private let phone = "com.apple.health.phone"
private let (inBed, asleep, awake, core, deep, rem) = (0, 1, 2, 3, 4, 5)

private func record(
  _ start: Date, _ end: Date, _ value: Int, source: String = watch
) -> CardSleepRecord {
  CardSleepRecord(start: ms(start), end: ms(end), value: value, source: source)
}

/// A Watch's night ending on `day` (of October unless `month` says otherwise): in bed at 22:30
/// the evening before; Core from 23:00, awake 01:00 to 01:10, Deep to 03:00, REM to 06:30, awake
/// to 06:45, and in bed to 06:50. `F` is 23:00, `W` 06:30.
private func watchNight(_ day: Int, month: Int = 10) -> [CardSleepRecord] {
  let midnight = date(month, day)
  func at(_ hours: Double) -> Date { midnight.addingTimeInterval(hours * 3600) }
  return [
    record(at(-1.5), at(6 + 50 / 60), inBed),
    record(at(-1), at(1), core),
    record(at(1), at(1 + 10 / 60), awake),
    record(at(1 + 10 / 60), at(3), deep),
    record(at(3), at(6.5), rem),
    record(at(6.5), at(6.75), awake),
  ]
}

/// Heart rate a minute over `span`, each a minute long, valued by `value`.
private func everyMinute(
  _ span: Range<Date>, source: String = watch, value: (Date) -> Double
) -> [CardReading] {
  stride(from: span.lowerBound, to: span.upperBound, by: 60).map {
    reading($0, value($0), source: source)
  }
}

private func windowCard(_ series: String, bucket: String = "night", formulas: String = "[]") throws
  -> CardSpec
{
  try spec(
    #"{"version": 1, "display": {"name": "Card"}, "series": [\#(series)], "formulas": \#(formulas), "bucket": "\#(bucket)", "range": "W"}"#
  )
}

struct CardWindowsTests {
  // MARK: - Nights

  /// Sleep's nights: one source, its main session, a day's sleep told apart, falling asleep and
  /// waking from the stretches asleep.
  @Test
  func nightsAreSleepsNights() {
    let records =
      watchNight(20)
      // An iPhone's estimate of the same night, with less time asleep: another source.
      + [record(date(10, 19, 23, 30), date(10, 20, 5, 30), asleep, source: phone)]
      // A nap that afternoon, 8 hours after waking: another session.
      + [record(date(10, 20, 15), date(10, 20, 16), core)]
      // Only a day's sleep on Oct 22.
      + [record(date(10, 22, 13), date(10, 22, 14, 30), core)]
    let nights = CardNights.nights(
      records.sorted { $0.start < $1.start }, days: date(10, 19)..<date(10, 26),
      calendar: london)
    #expect(nights.map(\.day) == [date(10, 20), date(10, 22)])
    let night = nights[0]
    #expect(Set(night.records.map(\.source)) == [watch])
    #expect(night.records.count == 5)
    #expect(night.fallingAsleep == ms(date(10, 19, 23)))
    #expect(night.waking == ms(date(10, 20, 6, 30)))
    #expect(
      night.asleepStretches == [
        CardStretch(start: ms(date(10, 19, 23)), end: ms(date(10, 20, 1))),
        CardStretch(start: ms(date(10, 20, 1, 10)), end: ms(date(10, 20, 6, 30))),
      ])
    // In bed from 22:30 to 06:50.
    #expect(night.inBed == (8 * 60 + 20) * 60_000)
    #expect(night.nightBedtime(calendar: london) == -1)
    // A day's sleep is a night of Sleep's page, but no night's sleep.
    #expect(nights[1].nightBedtime(calendar: london) == nil)
    #expect(
      CardNights.recordRange(days: date(10, 19)..<date(10, 26))
        == ms(date(10, 18, 18))..<ms(date(10, 25, 18)))
  }

  /// A source's records split into sessions where sleep stops for 3 hours or more, the one with
  /// the most sleep being the night; ties between sources go to the bundle ID that sorts first.
  @Test
  func theMainSessionAndTheSourceTies() {
    let records = [
      // 30 minutes from 19:00, then 6 hours from 22:30: 3 hours apart, two sessions.
      record(date(10, 19, 19), date(10, 19, 19, 30), core, source: "b"),
      record(date(10, 19, 22, 30), date(10, 20, 4, 30), core, source: "b"),
      // As much sleep from another source that sorts after it.
      record(date(10, 19, 19), date(10, 19, 19, 30), asleep, source: "c"),
      record(date(10, 19, 22, 30), date(10, 20, 4, 30), asleep, source: "c"),
    ]
    let nights = CardNights.nights(records, days: date(10, 20)..<date(10, 21), calendar: london)
    #expect(nights.count == 1)
    #expect(nights[0].records == [records[1]])
    #expect(nights[0].fallingAsleep == ms(date(10, 19, 22, 30)))
  }

  /// A night without stages (an iPhone's estimate): Asleep records are its stretches asleep.
  @Test
  func aNightWithoutStages() throws {
    let sleep = [
      record(date(10, 19, 23, 30), date(10, 20, 2), asleep, source: phone),
      record(date(10, 20, 2), date(10, 20, 2, 20), awake, source: phone),
      record(date(10, 20, 2, 20), date(10, 20, 6), asleep, source: phone),
    ]
    let readings = everyMinute(date(10, 19, 22)..<date(10, 20, 8)) { _ in 60 }
    let data = run(
      try windowCard(
        #"{"type": "Heart Rate", "aggregation": "count", "window": {"kind": "asleep"}}"#),
      .week, on: date(10, 20), readings: [heartRate: readings], sleep: sleep)
    // 23:30 to 02:00 and 02:20 to 06:00: 150 and 220 minutes.
    #expect(data.series[0].points.map(\.value) == [370])
    #expect(data.series[0].points.map(\.start) == [date(10, 20)])
  }

  // MARK: - The example cards

  /// Example 2: heart rate while asleep, per night. Lying awake in the night, and before and after
  /// sleep, doesn't count, and each stretch asleep weighs its readings on its own.
  @Test
  func sleepingHeartRate() throws {
    let card = try spec(
      #"{"version": 1, "display": {"name": "Sleeping Heart Rate", "symbol": "bed.double.fill", "color": "indigo"}, "series": [{"type": "Heart Rate", "window": {"kind": "asleep"}}], "bucket": "night", "range": "W", "chart": {"style": "line"}}"#
    )
    // Every 5 minutes: 50 in the first stretch asleep, 56 in the second, 70 awake in the night,
    // 80 up. The second night's 2 higher.
    var readings: [CardReading] = []
    for (day, plus) in [(20, 0.0), (21, 2.0)] {
      let midnight = date(10, day)
      readings += stride(from: -120, to: 480, by: 5).map { minute in
        let value: Double =
          switch minute {
          case -60..<60: 50
          case 60..<70: 70
          case 70..<390: 56
          default: 80
          }
        return reading(
          midnight.addingTimeInterval(Double(minute) * 60), value + plus, minutes: 0.5)
      }
    }
    let data = run(
      card, .week, on: date(10, 20), readings: [heartRate: readings],
      sleep: watchNight(20) + watchNight(21))
    let points = data.series[0].points
    #expect(data.bucket == .night)
    #expect(points.map(\.start) == [date(10, 20), date(10, 21)])
    // 24 readings at 50 and 64 at 56, each 5 minutes, the last of each stretch to its end.
    #expect(points.map(\.readings) == [88, 88])
    #expect(abs(points[0].value - (24 * 50 + 64 * 56) / 88.0) < 1e-12)
    #expect(abs(points[1].value - (24 * 52 + 64 * 58) / 88.0) < 1e-12)
    #expect(points[0].minimum == 50)
    #expect(points[0].maximum == 56)
    #expect(abs(data.summary!.value! - (points[0].value + points[1].value) / 2) < 1e-12)
  }

  /// Example 4: heart rate in the 5 minutes before falling asleep, per night: a lone reading counts
  /// to the stretch's end, not the hour after it.
  @Test
  func heartRateBeforeSleep() throws {
    let card = try spec(
      #"{"version": 1, "display": {"name": "Before Sleep", "symbol": "moon.zzz.fill", "color": "indigo"}, "series": [{"type": "Heart Rate", "window": {"kind": "beforeSleep", "minutes": 5}}], "bucket": "night", "range": "W", "chart": {"style": "dots"}}"#
    )
    // A reading a minute, from 60 at 22:55 up by one a minute.
    let readings = everyMinute(date(10, 19, 22)..<date(10, 20, 1)) {
      60 + $0.timeIntervalSince(date(10, 19, 22, 55)) / 60
    }
    let data = run(
      card, .week, on: date(10, 20), readings: [heartRate: readings], sleep: watchNight(20))
    #expect(
      data.series[0].points == [
        CardPoint(start: date(10, 20), value: 62, minimum: 60, maximum: 64, readings: 5)
      ])
    let lone = run(
      card, .week, on: date(10, 20),
      readings: [heartRate: [reading(date(10, 19, 22, 56), 70), reading(date(10, 19, 23), 90)]],
      sleep: watchNight(20))
    #expect(lone.series[0].points.map(\.value) == [70])

    // After waking: 06:30 to 07:00.
    let morning = everyMinute(date(10, 20, 6)..<date(10, 20, 8)) { _ in 70 }
    let after = run(
      try windowCard(
        #"{"type": "Heart Rate", "aggregation": "count", "window": {"kind": "afterWaking", "minutes": 30}}"#
      ), .week, on: date(10, 20), readings: [heartRate: readings + morning],
      sleep: watchNight(20))
    #expect(after.series[0].points.map(\.value) == [30])
  }

  // MARK: - Edge cases

  /// Nights across both of London's daylight saving changes: a night is its day's, its stretches
  /// are true lengths, and its point starts at its day's midnight.
  @Test(arguments: [(3, 29, 7.0), (10, 25, 9.0)])
  func nightsOverDaylightSaving(month: Int, day: Int, hoursAsleep: Double) throws {
    let evening = london.date(byAdding: .day, value: -1, to: date(month, day))!
      .addingTimeInterval(23 * 3600)
    let sleep = [record(evening, date(month, day, 7), core)]
    #expect(date(month, day, 7).timeIntervalSince(evening) == hoursAsleep * 3600)
    let readings = everyMinute(evening.addingTimeInterval(-3600)..<date(month, day, 9)) { _ in 60 }
    let data = run(
      try windowCard(
        #"{"type": "Heart Rate", "aggregation": "count", "window": {"kind": "asleep"}}"#),
      .week, on: date(month, day), readings: [heartRate: readings], sleep: sleep)
    #expect(data.series[0].points.map(\.start) == [date(month, day)])
    #expect(data.series[0].points.map(\.value) == [hoursAsleep * 60])
    let before = run(
      try windowCard(
        #"{"type": "Heart Rate", "aggregation": "count", "window": {"kind": "beforeSleep", "minutes": 90}}"#
      ), .week, on: date(month, day), readings: [heartRate: readings], sleep: sleep)
    #expect(before.series[0].points.map(\.value) == [60])
  }

  /// A reading in two nights' stretches counts for the later night: a long day's sleep from one
  /// source runs into the next night from another.
  @Test
  func aReadingInTwoNightsCountsForTheLater() throws {
    let sleep = [
      // Oct 20's: from 10 AM (before noon, so a night's) to 8 PM.
      record(date(10, 20, 10), date(10, 20, 20), asleep, source: "com.example.a"),
      // Oct 21's, from 7 PM, another source.
      record(date(10, 20, 19), date(10, 21, 3), asleep, source: "com.example.b"),
    ]
    let readings = [
      reading(date(10, 20, 15), 60), reading(date(10, 20, 19, 30), 70),
      reading(date(10, 21, 2), 80),
    ]
    let data = run(
      try windowCard(
        #"{"type": "Heart Rate", "aggregation": "max", "window": {"kind": "asleep"}}"#),
      .week, on: date(10, 20), readings: [heartRate: readings], sleep: sleep)
    #expect(
      data.series[0].points.map { [$0.value, Double($0.readings ?? 0)] } == [[60, 1], [80, 2]])
    #expect(data.series[0].points.map(\.start) == [date(10, 20), date(10, 21)])

    let resolved = CardWindows.latestOwnerWins([
      (CardStretch(start: 0, end: 100), 0), (CardStretch(start: 50, end: 80), 1),
      (CardStretch(start: 90, end: 120), 1),
    ])
    #expect(
      resolved.map { [$0.stretch.start, $0.stretch.end, $0.night] } == [
        [0, 50, 0], [50, 80, 1], [80, 90, 0], [90, 120, 1],
      ])
  }

  /// A night's readings go to the week of the day it ends on, even from the evening before: a
  /// period holds its days' nights.
  @Test
  func nightsByTheWeek() throws {
    // Monday Oct 19's night starts on Sunday Oct 18.
    let sleep = watchNight(19) + watchNight(20) + watchNight(26)
    let readings = everyMinute(date(10, 18, 20)..<date(10, 26, 12)) { _ in 60 }
    let card = try spec(
      #"{"version": 1, "display": {"name": "Card"}, "series": [{"type": "Heart Rate", "aggregation": "count", "window": {"kind": "asleep"}}], "bucket": "week", "range": "M"}"#
    )
    let data = run(card, .month, on: date(10, 20), readings: [heartRate: readings], sleep: sleep)
    // 440 minutes asleep a night.
    #expect(data.series[0].points.map(\.start) == [date(10, 19), date(10, 26)])
    #expect(data.series[0].points.map(\.value) == [880, 440])
  }

  /// A series without a sleep window, in a night card, is bucketed by calendar day, the night's:
  /// sleeping heart rate above the day's resting heart rate.
  @Test
  func sleepingHeartRateAboveResting() throws {
    let card = try windowCard(
      #"{"type": "Heart Rate", "window": {"kind": "asleep"}, "hidden": true}, {"type": "Resting Heart Rate", "hidden": true}"#,
      formulas: #"[{"id": "gap", "kind": "difference", "of": ["a", "b"]}]"#)
    let data = run(
      card, .week, on: date(10, 20),
      readings: [
        heartRate: everyMinute(date(10, 19, 22)..<date(10, 20, 8)) { _ in 58 },
        "HKQuantityTypeIdentifierRestingHeartRate": [reading(date(10, 20, 9), 52)],
      ],
      sleep: watchNight(20))
    #expect(data.formulas[0].points == [CardFormulaPoint(start: date(10, 20), value: 6)])
  }

  /// A moving average of nights reads the nights before the period.
  @Test
  func aMovingAverageOfNights() throws {
    let card = try windowCard(
      #"{"type": "Heart Rate", "aggregation": "count", "window": {"kind": "beforeSleep", "minutes": 10}}"#,
      formulas: #"[{"id": "trend", "kind": "movingAverage", "of": "a", "points": 3}]"#)
    let run = CardRun(
      spec: card, range: .week, date: date(10, 20), now: date(10, 20), calendar: london)
    // Two nights before Monday Oct 19's.
    #expect(
      run.windowFetches == [.sleep(CardNights.recordRange(days: date(10, 17)..<date(10, 26)))])
    // Its readings only once windowed.
    #expect(run.fetches.isEmpty)
    #expect(run.compute([]).series[0].points.isEmpty)
    let windowed = run.windowed([.sleep(watchNight(18) + watchNight(19))])
    #expect(windowed.windowFetches.isEmpty)
    #expect(
      windowed.fetches.map(\.kind) == [
        .stretchReadings(
          [
            CardStretch(start: ms(date(10, 17, 22, 50)), end: ms(date(10, 17, 23))),
            CardStretch(start: ms(date(10, 18, 22, 50)), end: ms(date(10, 18, 23))),
          ], filter: nil, needsSampleIDs: false)
      ])
    let data = windowed.compute([
      .readings(
        everyMinute(date(10, 17, 22, 50)..<date(10, 17, 23)) { _ in 60 }
          + everyMinute(date(10, 18, 22, 54)..<date(10, 18, 23)) { _ in 60 })
    ])
    #expect(data.series[0].points.map(\.value) == [6])
    #expect(data.formulas[0].points.map(\.value) == [8])
  }

  // MARK: - Workouts

  /// Readings during workouts, of the activities given, overlapping workouts merged.
  @Test
  func workoutsByActivity() throws {
    let (running, cycling, walking) = (37, 13, 52)
    let workouts = [
      CardWorkout(start: ms(date(10, 20, 7)), end: ms(date(10, 20, 7, 30)), activityType: running),
      CardWorkout(start: ms(date(10, 20, 18)), end: ms(date(10, 20, 19)), activityType: cycling),
      // Two runs recorded over each other: 07:00 to 08:00.
      CardWorkout(start: ms(date(10, 21, 7)), end: ms(date(10, 21, 7, 45)), activityType: running),
      CardWorkout(start: ms(date(10, 21, 7, 30)), end: ms(date(10, 21, 8)), activityType: running),
      CardWorkout(
        start: ms(date(10, 21, 12)), end: ms(date(10, 21, 12, 30)), activityType: walking),
    ]
    let readings = everyMinute(date(10, 20, 6)..<date(10, 21, 20)) { at in
      workouts.first { ms(at) >= $0.start && ms(at) < $0.end }.map {
        $0.activityType == running ? 150 : 120
      } ?? 70
    }
    func points(_ activities: String) throws -> [[Double]] {
      let card = try windowCard(
        #"{"type": "Heart Rate", "aggregation": "max", "window": {"kind": "workout", "activities": \#(activities)}}"#,
        bucket: "day")
      return run(card, .week, on: date(10, 20), readings: [heartRate: readings], workouts: workouts)
        .series[0].points.map { [$0.value, Double($0.readings ?? 0)] }
    }
    #expect(try points("[37]") == [[150, 30], [150, 60]])
    #expect(try points(#"["Cycling", "Walking"]"#) == [[120, 60], [120, 30]])
    #expect(try points("null") == [[150, 90], [150, 90]])

    let workoutRun = CardRun(
      spec: try windowCard(
        #"{"type": "Heart Rate", "window": {"kind": "workout"}}"#, bucket: "day"),
      range: .week, date: date(10, 20), now: date(10, 20), calendar: london)
    #expect(workoutRun.windowFetches == [.workouts(ms(date(10, 19))..<ms(date(10, 26)))])
  }

  /// A workout across the period's end weighs its last reading as without the period.
  @Test
  func aWorkoutAcrossThePeriodsEnd() throws {
    let workouts = [
      CardWorkout(start: ms(date(10, 20, 23, 30)), end: ms(date(10, 21, 0, 30)), activityType: 37)
    ]
    let readings = [
      reading(date(10, 20, 23, 30), 100), reading(date(10, 20, 23, 50), 160),
      reading(date(10, 21, 0, 10), 120),
    ]
    let day = CardRun(
      spec: try spec(
        #"{"version": 1, "display": {"name": "Card"}, "series": [{"type": "Heart Rate", "window": {"kind": "workout"}}], "bucket": "hour", "range": "D"}"#
      ), range: .day, date: date(10, 20), now: date(10, 20), calendar: london)
    let windowed = day.windowed([.workouts(workouts)])
    let data = windowed.compute(windowed.fetches.map { _ in .readings(readings) })
    // 100 for 20 minutes, 160 for 20, to the next reading past the period.
    #expect(data.series[0].points.map(\.value) == [130])
  }
}
