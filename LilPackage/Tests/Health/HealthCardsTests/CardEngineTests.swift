import Foundation
import HealthCatalog
import Testing

@testable import HealthCards

// The engine's shared core on synthetic readings (docs/decisions/cards.md, What an engine
// computes). The Mac's fetching is tested in HealthDatabaseTests (CardQueriesTests).

struct CardEngineTests {
  // MARK: - Weights

  @Test
  func timeWeightedReadingsCountUntilTheirSourcesNextOrForTheirDuration() {
    let readings = [
      CardReading(start: 0, end: 10_000, value: 60, source: "watch"),
      CardReading(start: 30_000, end: 31_000, value: 70, source: "phone"),
      CardReading(start: 60_000, end: 61_000, value: 80, source: "watch"),
      // Its last: its own duration, at least a second.
      CardReading(start: 120_000, end: 120_200, value: 90, source: "watch"),
    ]
    #expect(CardWeights.weights(of: readings, .discreteTemporallyWeighted) == [60, 1, 60, 1])
    #expect(CardWeights.weights(of: readings, .discreteArithmetic) == [1, 1, 1, 1])
  }

  @Test
  func inAWindowEachStretchIsOnItsOwn() {
    let stretches = [
      CardStretch(start: 0, end: 300_000), CardStretch(start: 1_000_000, end: 9_000_000),
    ]
    let readings = [
      CardReading(start: 0, end: 1_000, value: 60, source: "watch"),
      CardReading(start: 60_000, end: 61_000, value: 62, source: "watch"),
      // The next is in another stretch: it counts to its own stretch's end.
      CardReading(start: 200_000, end: 201_000, value: 64, source: "watch"),
      // A lone reading counts until the stretch ends, at most an hour.
      CardReading(start: 1_000_000, end: 1_001_000, value: 66, source: "watch"),
    ]
    let weights = CardWeights.weights(
      of: readings, stretches: stretches, stretchIndices: [0, 0, 0, 1],
      .discreteTemporallyWeighted)
    #expect(weights == [60, 140, 100, 3600])
  }

  @Test
  func readingsAreInAWindowByTheirStart() {
    let stretches = [CardStretch(start: 10, end: 20), CardStretch(start: 30, end: 40)]
    let readings = [5, 10, 19, 20, 35, 40].map {
      CardReading(start: $0, end: $0 + 100, value: 1, source: "s")
    }
    let kept = CardWindows.readings(readings, in: stretches)
    #expect(kept.readings.map(\.start) == [10, 19, 35])
    #expect(kept.stretchIndices == [0, 0, 1])
  }

  // MARK: - Times of day

  @Test
  func aTimeOfDayIsEachDaysHoursOnTheClock() {
    let window = CardTimeOfDay(from: CardClockTime("00:00")!, to: CardClockTime("12:00")!)
    let stretches = window.stretches(
      in: ms(date(1, 10))..<ms(date(1, 12)), timeZone: london.timeZone)
    #expect(
      stretches == [
        CardStretch(start: ms(date(1, 10)), end: ms(date(1, 10, 12))),
        CardStretch(start: ms(date(1, 11)), end: ms(date(1, 11, 12))),
      ])
  }

  @Test
  func aTimeOfDayCanCrossMidnight() {
    let window = CardTimeOfDay(from: CardClockTime("22:00")!, to: CardClockTime("06:00")!)
    let stretches = window.stretches(
      in: ms(date(1, 10))..<ms(date(1, 12)), timeZone: london.timeZone)
    #expect(
      stretches == [
        CardStretch(start: ms(date(1, 10)), end: ms(date(1, 10, 6))),
        CardStretch(start: ms(date(1, 10, 22)), end: ms(date(1, 11, 6))),
        CardStretch(start: ms(date(1, 11, 22)), end: ms(date(1, 12))),
      ])
  }

  /// The day clocks go forward has no 1 AM hour, and the day they go back has two.
  @Test
  func aTimeOfDayFollowsTheClockOverDaylightSaving() {
    let oneToTwo = CardTimeOfDay(from: CardClockTime("01:00")!, to: CardClockTime("02:00")!)
    let spring = oneToTwo.stretches(
      in: ms(date(3, 29))..<ms(date(3, 30)), timeZone: london.timeZone)
    #expect(spring.isEmpty)
    let autumn = oneToTwo.stretches(
      in: ms(date(10, 25))..<ms(date(10, 26)), timeZone: london.timeZone)
    #expect(autumn.map { ($0.end - $0.start) / 60_000 } == [120])
    let morning = CardTimeOfDay(from: CardClockTime("00:00")!, to: CardClockTime("12:00")!)
    let short = morning.stretches(
      in: ms(date(3, 29))..<ms(date(3, 30)), timeZone: london.timeZone)
    #expect(short.map { ($0.end - $0.start) / 3_600_000 } == [11])
  }

  /// Stretches keep exactly the readings the clock rule keeps, every 7 minutes over both changes.
  @Test(arguments: [("01:00", "02:00"), ("22:00", "06:00"), ("00:30", "01:30"), ("07:00", "23:59")])
  func stretchesAgreeWithTheClockRule(from: String, to: String) {
    let window = CardTimeOfDay(from: CardClockTime(from)!, to: CardClockTime(to)!)
    for (start, end) in [(date(3, 28), date(3, 31)), (date(10, 24), date(10, 27))] {
      let span = ms(start)..<ms(end)
      let stretches = window.stretches(in: span, timeZone: london.timeZone)
      for moment in stride(from: span.lowerBound, to: span.upperBound, by: 7 * 60_000 + 13) {
        let parts = london.dateComponents(
          [.hour, .minute, .second, .nanosecond],
          from: Date(timeIntervalSince1970: Double(moment) / 1000))
        let seconds =
          Double(parts.hour! * 3600 + parts.minute! * 60 + parts.second!)
          + Double(parts.nanosecond!) / 1e9
        let inStretch = stretches.contains { $0.start <= moment && moment < $0.end }
        #expect(
          inStretch == window.contains(secondsSinceMidnight: seconds),
          "\(from)–\(to) at \(Date(timeIntervalSince1970: Double(moment) / 1000))")
      }
    }
  }

  // MARK: - Aggregations and buckets

  private func weightCard(
    _ aggregation: String, bucket: String = "day", range: String = "W"
  ) throws -> CardSpec {
    try spec(
      #"{"version": 1, "display": {"name": "W"}, "series": [{"type": "Weight", "aggregation": "\#(aggregation)"}], "bucket": "\#(bucket)", "range": "\#(range)", "chart": {"style": "dots"}}"#
    )
  }

  @Test(arguments: [
    ("avg", 3.0), ("min", 1.0), ("max", 5.0), ("first", 3.0), ("latest", 5.0), ("count", 3.0),
  ])
  func eachAggregationOfADay(aggregation: String, value: Double) throws {
    let readings = [
      reading(date(10, 20, 9), 3), reading(date(10, 20, 10), 1), reading(date(10, 20, 11), 5),
    ]
    let data = run(
      try weightCard(aggregation), .week, on: date(10, 20), readings: [bodyMass: readings])
    let point = try #require(data.series[0].points.first)
    #expect(data.series[0].points.count == 1)
    #expect(point.start == date(10, 20))
    #expect(point.value == value)
    #expect(point.readings == 3)
    if aggregation == "count" {
      #expect(point.minimum == 3 && point.maximum == 3)
      #expect(data.series[0].unit == .readings)
    } else {
      #expect(point.minimum == 1 && point.maximum == 5)
      #expect(data.series[0].unit == .catalog("kg"))
    }
  }

  @Test
  func firstAndLatestBreakTiesByEndThenSampleID() throws {
    let readings = [
      reading(date(10, 20, 8), 70, minutes: 2, id: "b"),
      reading(date(10, 20, 8), 71, minutes: 1, id: "c"),
      reading(date(10, 20, 8), 72, minutes: 1, id: "a"),
      reading(date(10, 20, 20), 80, minutes: 1, id: "a"),
      reading(date(10, 20, 20), 81, minutes: 1, id: "b"),
    ]
    let first = run(
      try weightCard("first"), .week, on: date(10, 20), readings: [bodyMass: readings])
    #expect(first.series[0].points.map(\.value) == [72])
    #expect(first.summary == CardSummary(kind: .first, value: 72))
    let latest = run(
      try weightCard("latest"), .week, on: date(10, 20), readings: [bodyMass: readings])
    #expect(latest.series[0].points.map(\.value) == [81])
    #expect(latest.summary == CardSummary(kind: .latest, value: 81))
  }

  @Test
  func bucketsFollowTheCalendar() throws {
    let readings = (0..<120).map {
      reading(date(9, 1).addingTimeInterval(Double($0) * 86_400 + 3600), 70)
    }
    // auto: hours at D, days at W and M, weeks at 6M, months at Y.
    let auto = try weightCard("avg", bucket: "auto")
    #expect(run(auto, .day, on: date(10, 20), readings: [bodyMass: readings]).grain == .hour)
    #expect(
      run(auto, .week, on: date(10, 20), readings: [bodyMass: readings]).series[0].points.map(
        \.start) == (19...25).map { date(10, $0) })
    let year = run(auto, .year, on: date(10, 20), readings: [bodyMass: readings])
    #expect(year.series[0].points.map(\.start) == (9...12).map { date($0, 1) })
    // A week at M starts on the calendar's first weekday, before the month, and counts only the
    // month's readings.
    let weeks = run(
      try weightCard("count", bucket: "week", range: "M"), .month, on: date(10, 20),
      readings: [bodyMass: readings])
    #expect(weeks.series[0].points.first?.start == date(9, 28))
    #expect(weeks.series[0].points.first?.value == 4)
    #expect(weeks.series[0].points.map(\.value).reduce(0, +) == 31)
  }

  // MARK: - Totals

  /// 100 steps an hour from 8 AM to 6 PM, every day but Sundays.
  private var hourlySteps: [CardTotal] {
    (0..<400).flatMap { day -> [CardTotal] in
      let start = london.date(byAdding: .day, value: day, to: date(1, 1, year: 2026))!
      guard london.component(.weekday, from: start) != 1 else { return [] }
      return (8..<18).map { hour in
        CardTotal(
          start: london.date(bySettingHour: hour, minute: 0, second: 0, of: start)!, sum: 100)
      }
    }
  }

  @Test
  func aTotalChartsAsMetricDetail() throws {
    let seed = HealthCards.welcomeSeed[0].spec
    let totals = [steps: hourlySteps]
    let day = run(seed, .day, on: date(10, 20), hourlyTotals: totals)
    #expect(day.grain == .hour)
    #expect(day.series[0].points.count == 10)
    #expect(day.series[0].points[0].readings == nil)
    #expect(day.summary == CardSummary(kind: .total, value: 1000))
    // A week: a day's total each, and its average day with steps.
    let week = run(seed, .week, on: date(10, 20), hourlyTotals: totals)
    #expect(week.series[0].points.map(\.value) == Array(repeating: 1000, count: 6))
    #expect(week.summary == CardSummary(kind: .average, value: 1000))
    // 6M: each week's average day, captioned DAILY AVERAGE.
    let sixMonths = run(seed, .sixMonths, on: date(10, 20), hourlyTotals: totals)
    #expect(sixMonths.grain == .week)
    #expect(sixMonths.series[0].points.allSatisfy { $0.value == 1000 })
    #expect(sixMonths.summary == CardSummary(kind: .dailyAverage, value: 1000))
  }

  @Test
  func aFixedBucketTotalsEachBucket() throws {
    var card = HealthCards.welcomeSeed[0].spec
    card.bucket = .week
    card.range = .month
    let data = run(card, .month, on: date(10, 20), hourlyTotals: [steps: hourlySteps])
    // Oct 2026's weeks from Monday Sep 28: its first has Oct 1–3, three days.
    #expect(data.series[0].points.first == CardPoint(start: date(9, 28), value: 3000))
    #expect(
      data.series[0].points.map(\.start)
        == [28, 5, 12, 19, 26].enumerated().map {
          date($0.offset == 0 ? 9 : 10, $0.element)
        })
    #expect(data.summary?.kind == .average)
    #expect(data.summary?.value == 27_000.0 / 5)
  }

  // MARK: - Formulas and summaries

  /// Example 5: the first weigh-in before noon each day, and its 7-day rolling average.
  @Test
  func morningWeight() throws {
    let card = try spec(
      #"{"version": 1, "display": {"name": "Morning Weight", "symbol": "scalemass.fill", "color": "purple"}, "series": [{"type": "Weight", "aggregation": "first", "window": {"kind": "timeOfDay", "from": "00:00", "to": "12:00"}, "label": "First weigh-in before noon"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7, "label": "7-day rolling average"}], "bucket": "day", "range": "M", "chart": {"style": "dots"}}"#
    )
    // From Sep 25: a weigh-in at 7:30, another at 8:00 and one in the evening, but on Oct 5 only
    // after noon.
    var readings: [CardReading] = []
    for offset in 0..<20 {
      let day = london.date(byAdding: .day, value: offset, to: date(9, 25))!
      let morning = 70 + Double(offset) / 10
      if london.component(.day, from: day) == 5 {
        readings.append(reading(day.addingTimeInterval(13 * 3600), 90))
        continue
      }
      readings += [
        reading(day.addingTimeInterval(7.5 * 3600), morning),
        reading(day.addingTimeInterval(8 * 3600), morning + 1),
        reading(day.addingTimeInterval(19 * 3600), morning + 5),
      ]
    }
    let data = run(card, .month, on: date(10, 20), readings: [bodyMass: readings])
    let series = data.series[0]
    #expect(series.label == "First weigh-in before noon")
    #expect(series.points.map(\.start).contains(date(10, 5)) == false)
    #expect(series.points.first?.start == date(10, 1))
    #expect(series.points.first?.value == 70.6)
    #expect(series.points.count == 13)
    // Oct 1's average reaches back to Sep 25: 70.0 to 70.6.
    let trend = data.formulas[0]
    #expect(trend.label == "7-day rolling average")
    #expect(trend.points.count == series.points.count)
    #expect(abs(trend.points[0].value - 70.3) < 1e-9)
    // Oct 8's window is Oct 2–8, without Oct 5: 70.7, 70.8, 70.9, 71.1, 71.2, 71.3.
    let october8 = try #require(trend.points.first { $0.start == date(10, 8) })
    #expect(abs(october8.value - (70.7 + 70.8 + 70.9 + 71.1 + 71.2 + 71.3) / 6) < 1e-9)
    #expect(data.summary == CardSummary(kind: .first, value: 70.6))
  }

  /// Example 1, and example 3's dots with a 7-point moving average.
  @Test
  func bodyTemperatureAndHRV() throws {
    let temperature = try spec(
      #"{"version": 1, "display": {"name": "Body Temperature", "symbol": "thermometer.medium", "color": "red"}, "series": [{"type": "BodyTemperature"}], "range": "M", "chart": {"style": "line"}}"#
    )
    let temperatures = (1...10).map { reading(date(10, $0, 7), 36.5 + Double($0 % 3) / 10) }
    let data = run(temperature, .month, on: date(10, 20), readings: [bodyTemperature: temperatures])
    #expect(data.series[0].points.count == 10)
    #expect(data.series[0].unit == .catalog("degC"))
    #expect(abs(data.summary!.value! - temperatures.map(\.value).reduce(0, +) / 10) < 1e-12)

    let hrvCard = try spec(
      #"{"version": 1, "display": {"name": "HRV", "symbol": "waveform.path.ecg", "color": "pink"}, "series": [{"type": "HeartRateVariabilitySDNN"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7}], "range": "M", "chart": {"style": "dots"}}"#
    )
    let hrvs = (0..<40).map {
      reading(date(9, 10).addingTimeInterval(Double($0) * 86_400 + 6 * 3600), Double(40 + $0))
    }
    let hrvData = run(hrvCard, .month, on: date(10, 20), readings: [hrv: hrvs])
    // Oct 1 is day 21: its average is days 15 to 21.
    #expect(hrvData.formulas[0].points.first == CardFormulaPoint(start: date(10, 1), value: 58))
    #expect(hrvData.formulas[0].points.count == 19)
  }

  @Test
  func aRangesCardsHeaderIsItsRangeOrItsAverage() throws {
    let seed = HealthCards.welcomeSeed[1].spec
    let readings = [reading(date(10, 20, 9), 60), reading(date(10, 21, 9), 90)]
    let data = run(seed, .week, on: date(10, 20), readings: [heartRate: readings])
    #expect(data.summary == CardSummary(kind: .range, value: nil, minimum: 60, maximum: 90))
    let same = run(seed, .week, on: date(10, 20), readings: [heartRate: [readings[0]]])
    #expect(same.summary == CardSummary(kind: .average, value: 60))
    #expect(run(seed, .week, on: date(9, 1), readings: [heartRate: readings]).summary == nil)
  }

  /// Sleeping HR minus resting HR, without the sleep window (851-3196): every series hidden, the
  /// formula is the lead.
  @Test
  func aDifferenceOfHiddenSeries() throws {
    let card = try spec(
      #"{"version": 1, "display": {"name": "Gap"}, "series": [{"type": "Heart Rate", "hidden": true}, {"type": "Resting Heart Rate", "hidden": true}], "formulas": [{"id": "gap", "kind": "difference", "of": ["a", "b"]}], "bucket": "day", "range": "W", "chart": {"style": "line"}}"#
    )
    let data = run(
      card, .week, on: date(10, 20),
      readings: [
        heartRate: [reading(date(10, 20, 9), 70), reading(date(10, 21, 9), 75)],
        "HKQuantityTypeIdentifierRestingHeartRate": [reading(date(10, 20, 6), 55)],
      ])
    #expect(data.formulas[0].points == [CardFormulaPoint(start: date(10, 20), value: 15)])
    #expect(data.summary == CardSummary(kind: .average, value: 15))
    #expect(data.leadPoints == data.formulas[0].points)
  }

  // MARK: - Fetches

  @Test
  func readingsReachAnHourPastThePeriodForTimeWeighting() {
    let seed = HealthCards.welcomeSeed[1].spec
    let run = CardRun(
      spec: seed, range: .day, date: date(10, 20, 12), now: date(10, 20, 12), calendar: london)
    #expect(
      run.fetches == [
        CardFetch(
          series: 0, type: heartRate, purpose: .period,
          kind: .readings(
            ms(date(10, 20))..<(ms(date(10, 21)) + 3_600_000), filter: nil, needsSampleIDs: false))
      ])
  }

  @Test
  func aMovingAverageOfATotalFetchesTheBucketsBefore() throws {
    var card = HealthCards.welcomeSeed[0].spec
    card.formulas = [.init(id: "trend", operation: .movingAverage(of: "a", points: 3))]
    let run = CardRun(
      spec: card, range: .sixMonths, date: date(10, 20), now: date(10, 20), calendar: london)
    // 6M from May 1 (a Friday): its first week starts Monday Apr 27, two weeks after Apr 13.
    #expect(
      run.fetches.map(\.kind) == [
        .totals(date(5, 1)..<date(11, 1), grain: .day),
        .totals(date(4, 13)..<date(4, 27), grain: .day),
      ])
  }

  // MARK: - Headlines

  @Test
  func headlinesAreFoundAsSummaryFindsThem() throws {
    let seed = HealthCards.welcomeSeed
    #expect(seed[0].spec.headlineLookup == .latestData(type: steps))
    #expect(seed[1].spec.headlineLookup == .latestReading(type: heartRate))
    #expect(seed[5].spec.headlineLookup == .latestReading(type: bodyMass))
    #expect(try weightCard("max").headlineLookup == .latestData(type: bodyMass))
    var filtered = seed[1].spec
    filtered.series[0].filter = .init(deviceModels: ["Watch"])
    #expect(filtered.headlineLookup == .search)
    let ends = CardHeadline.searchEnds(for: filtered, now: date(10, 20, 9), calendar: london)
    #expect(ends.count == 8)
    #expect(ends[1] == date(10, 13))
    #expect(ends[7] == date(9, 1))
  }

  @Test
  func aHeadlinesRunIsTheSevenBucketsEndingOnIt() throws {
    let run = CardRun(
      headlineOf: HealthCards.welcomeSeed[0].spec, endingOn: date(10, 20, 9), calendar: london)
    #expect(run.grain == .day)
    #expect(run.interval == DateInterval(start: date(10, 14), end: date(10, 21)))
    let data = run.compute(fetch(run, readings: [:], hourlyTotals: [steps: hourlySteps]))
    let headline = try #require(CardHeadline(latestBucketOf: data))
    #expect(headline.value == 1000)
    #expect(headline.date == date(10, 20))
    #expect(data.series[0].points.count == 6)
  }

  // MARK: - Display units

  @Test
  func displayUnitsConvertFromTheCatalogsUnit() throws {
    let pound = try #require(CardDisplayUnit.conversion(from: "kg", to: "lb"))
    #expect(abs(70 * pound.scale - 154.32358) < 1e-5)
    let fahrenheit = try #require(CardDisplayUnit.conversion(from: "degC", to: "degF"))
    #expect(abs(37 * fahrenheit.scale + fahrenheit.offset - 98.6) < 1e-9)
    let miles = try #require(CardDisplayUnit.conversion(from: "m", to: "mi"))
    #expect(abs(1_609.344 * miles.scale - 1) < 1e-12)
    #expect(CardDisplayUnit.conversion(from: "count/min", to: "kg") == nil)
    #expect(CardDisplayUnit.conversion(from: "kg", to: "km") == nil)
  }
}
