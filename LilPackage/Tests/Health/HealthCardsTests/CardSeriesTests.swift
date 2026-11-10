import Testing

@testable import HealthCards

// Quantity series' values as readings in the engine's core (851-4172, docs/decisions/cards.md ›
// Readings and weights), on synthetic values. The server's `CardSeries.test.ts` is this, case
// for case.

private let watch = "com.apple.health.watch"
private let strap = "org.example.strap"

private func series(
  _ id: String, start: Int, times: [Double], values: [Double], durations: [Double]? = nil,
  source: String = watch
) -> CardSeries.Series {
  // The sample ends with its last value, as HealthKit's do.
  CardSeries.Series(
    sample: CardReading(
      start: start, end: start + Int(((times.max() ?? 0) * 1000).rounded()), value: 0,
      source: source, sampleID: id),
    start: start, times: times, durations: durations ?? times.map { _ in 0 }, values: values)
}

private func reading(
  _ start: Int, _ value: Double, end: Int? = nil, source: String = watch, id: String = ""
)
  -> CardReading
{
  CardReading(start: start, end: end ?? start, value: value, source: source, sampleID: id)
}

@Suite
struct CardSeriesTests {
  /// Each value starts its seconds after the series, to the millisecond, with its duration, and
  /// only those starting in the range are kept, half-open.
  @Test
  func readingsAreTheValuesStartingInTheRange() {
    let a = series(
      "a", start: 1_000_000, times: [0, 0.5, 1.234, 2], values: [60, 61, 62, 63],
      durations: [0, 0.25, 0, 0])
    #expect(
      Array(a.readings(in: 1_000_500..<1_002_000)) == [
        reading(1_000_500, 61, end: 1_000_750, id: "a"), reading(1_001_234, 62, id: "a"),
      ])
    #expect(a.readings(in: 0..<1).isEmpty)
  }

  /// Only values by the sample's end and less than a week after its start count, as the tools
  /// read them (851-4171); a time or duration outside 0 to 1e9 s is no values.
  @Test
  func valuesCountByTheSamplesEndAndWithinAWeek() {
    let week = Double(CardSeries.reach) / 1000
    let long = series("a", start: 0, times: [0, week - 1, week], values: [1, 2, 3])
    #expect(long.values?.map(\.value) == [1, 2])
    let past = CardSeries.Series(
      sample: CardReading(start: 0, end: 1000, value: 0, source: watch), start: 0,
      times: [0, 1, 2], durations: [0, 0, 0], values: [1, 2, 3])
    #expect(past.values?.map(\.value) == [1, 2])
    #expect(series("a", start: 0, times: [0, -1], values: [1, 2]).values == nil)
    #expect(series("a", start: 0, times: [0, 2e9], values: [1, 2]).values == nil)
    // From HealthKit's values too.
    let read = CardSeries.Series(
      sample: CardReading(start: 0, end: 1000, value: 0, source: watch),
      values: [
        CardReading(start: 0, end: 0, value: 1, source: watch),
        CardReading(start: 2000, end: 2000, value: 2, source: watch),
      ])
    #expect(read.values?.map(\.value) == [1])
  }

  /// A series whose arrays don't line up, or have no values, is read as its sample.
  @Test
  func seriesWithoutValuesAreTheirSample() {
    for broken in [
      series("a", start: 0, times: [0, 1], values: [60]),
      series("a", start: 0, times: [], values: []),
    ] {
      #expect(broken.values == nil)
      #expect(Array(broken.readings(in: 0..<10_000)) == [broken.sample])
      #expect(broken.readings(in: 1..<10_000).isEmpty)
    }
  }

  /// The series that can have readings in a range are those starting a week before it or later,
  /// and before its end; a series starts in it if its sample does.
  @Test
  func readingsOfSeriesInARange() {
    let day = CardSeries.reach
    let all = [
      series("a", start: 0, times: [0, 1], values: [1, 2]),
      series("b", start: day, times: [0, 1], values: [3, 4]),
      series("c", start: 2 * day, times: [0, 1], values: [5, 6]),
    ]
    #expect(
      CardSeries.readings(of: all, in: (day + 500)..<(2 * day + 1)).flatMap { $0.map(\.value) }
        == [4, 5])
    #expect(CardSeries.anyStarts(in: (day + 1)..<(2 * day + 1), all))
    #expect(!CardSeries.anyStarts(in: (day + 1)..<(2 * day), all))
    #expect(CardSeries.starts(for: 1_000_000_000..<2_000_000_000) == 395_200_000..<2_000_000_000)
  }

  /// Merged by start: a single sample before a value starting in the same millisecond, and
  /// overlapping series' values interleaved, those starting together in the series' order.
  @Test
  func mergedByStart() {
    let singles = [reading(1000, 1, source: strap), reading(3000, 3, source: strap)]
    let a = [reading(1000, 10, id: "a"), reading(2000, 20, id: "a"), reading(4000, 40, id: "a")]
    let b = [reading(2000, 21, id: "b"), reading(2500, 25, id: "b")]
    #expect(
      CardSeries.merged(singles, [a[...], b[...]]).map(\.value) == [1, 10, 20, 21, 25, 3, 40])
    #expect(CardSeries.merged(singles, []) == singles)
    #expect(CardSeries.merged([], [a[...]]) == a)
    // Series one after another need no sort.
    #expect(CardSeries.merged([], [b[...], a[2...]]).map(\.value) == [21, 25, 40])
  }

  /// The latest reading is a series' value after the latest sample's start, or the sample's own
  /// latest value when it's a series.
  @Test
  func latestReading() {
    let sample = reading(1000, 75, source: strap, id: "s")
    let later = [reading(1000, 60, id: "a"), reading(1500, 90, id: "a")]
    #expect(
      CardSeries.latestReading(sample: sample, sampleIsSeries: false, values: later).value == 90)
    // A value starting with the sample doesn't replace it.
    #expect(
      CardSeries.latestReading(sample: sample, sampleIsSeries: false, values: [later[0]]).value
        == 75)
    // The sample is the series: its latest value by now.
    #expect(
      CardSeries.latestReading(sample: later[0], sampleIsSeries: true, values: later).value == 90)
    // A series without values by now: its sample.
    #expect(
      CardSeries.latestReading(sample: sample, sampleIsSeries: true, values: []).value == 75)
  }

}
