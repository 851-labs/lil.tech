import Foundation
import HealthCatalog
import Testing

@testable import HealthCards

/// Canonical forms, the model, and the design's examples (docs/decisions/cards.md).
struct CardSpecTests {
  func spec(_ text: String) throws -> CardSpec {
    try CardSpec(inputJSON: Data(text.utf8))
  }

  /// The design's canonical form, word for word, keys in its order.
  @Test
  func canonicalFormOfTheLeastASpecNeeds() throws {
    let spec = try spec(
      #"{"version": 1, "display": {"name": "Steps"}, "series": [{"type": "Steps"}]}"#)
    #expect(
      spec.jsonText
        == #"{"version":1,"display":{"name":"Steps","symbol":"flame.fill","color":"orange","unit":null},"series":[{"id":"a","type":"HKQuantityTypeIdentifierStepCount","aggregation":"sum","window":null,"filter":null,"label":null,"hidden":false}],"formulas":[],"bucket":"auto","range":"W","chart":{"style":"bars","goal":null}}"#
    )
  }

  /// Example 4 as an agent may write it canonicalizes to the design's.
  @Test
  func exampleFourCanonicalizes() throws {
    let spec = try spec(
      #"{"version": 1, "display": {"name": "Heart Rate Before Sleep", "symbol": "bed.double.fill", "color": "mint"}, "series": [{"type": "Heart Rate", "window": {"kind": "beforeSleep", "minutes": 5}}], "bucket": "night", "range": "M", "chart": {"style": "dots"}}"#
    )
    #expect(
      spec
        == CardSpec(
          display: .init(name: "Heart Rate Before Sleep", symbol: "bed.double.fill", color: .mint),
          series: [
            .init(
              id: "a", type: "HKQuantityTypeIdentifierHeartRate", aggregation: .avg,
              window: .beforeSleep(minutes: 5))
          ],
          bucket: .night, range: .month, chart: .init(style: .dots)))
    // Canonical already: canonicalizing again changes nothing.
    #expect(try CardSpec(input: spec.json) == spec)
    #expect(CardSpec.storedErrors(spec.json).isEmpty)
  }

  @Test
  func theFourExampleCards() throws {
    let temperature = try spec(
      #"{"version": 1, "display": {"name": "Body Temperature", "symbol": "thermometer.medium", "color": "red"}, "series": [{"type": "BodyTemperature"}], "range": "M", "chart": {"style": "line"}}"#
    )
    #expect(temperature.series[0].aggregation == .avg)
    #expect(temperature.bucket == .auto)
    let sleeping = try spec(
      #"{"version": 1, "display": {"name": "Sleeping Heart Rate", "symbol": "moon.zzz.fill", "color": "indigo"}, "series": [{"type": "HeartRate", "window": {"kind": "asleep"}}], "bucket": "night", "range": "M", "chart": {"style": "line"}}"#
    )
    #expect(sleeping.series[0].window == .asleep)
    let hrv = try spec(
      #"{"version": 1, "display": {"name": "HRV", "symbol": "waveform.path.ecg", "color": "pink"}, "series": [{"type": "Heart Rate Variability"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7}], "range": "M"}"#
    )
    #expect(hrv.chart.style == .dots)
    #expect(hrv.formulas == [.init(id: "trend", operation: .movingAverage(of: "a", points: 7))])
    #expect(hrv.series[0].type == "HKQuantityTypeIdentifierHeartRateVariabilitySDNN")
  }

  @Test
  func beyondTheFour() throws {
    let gap = try spec(
      #"{"version": 1, "display": {"name": "Above Resting"}, "series": [{"type": "HeartRate", "window": {"kind": "asleep"}, "hidden": true}, {"type": "RestingHeartRate", "hidden": true}], "formulas": [{"id": "gap", "kind": "difference", "of": ["a", "b"]}], "bucket": "night"}"#
    )
    #expect(gap.lead == .formula(gap.formulas[0]))
    #expect(gap.valueUnit == .catalog("count/min"))
    #expect(gap.formulas[0].operation == .difference(of: "a", minus: "b"))
    #expect(gap.range == .week)

    let runs = try spec(
      #"{"version": 1, "display": {"name": "Runs"}, "series": [{"type": "HeartRate", "window": {"kind": "workout", "activities": ["running"]}}], "bucket": "day", "chart": {"style": "ranges"}}"#
    )
    #expect(runs.series[0].window == .workout(activities: [37]))

    let goal = try spec(
      #"{"version": 1, "display": {"name": "Steps"}, "series": [{"type": "StepCount"}], "chart": {"goal": {"value": 10000}}}"#
    )
    #expect(goal.chart == .init(style: .bars, goal: .init(value: 10_000)))
  }

  @Test
  func defaults() throws {
    // The first series' type gives the symbol, color and style.
    let weight = try spec(
      #"{"version": 1, "display": {"name": "W"}, "series": [{"type": "Weight"}]}"#)
    #expect(weight.display == .init(name: "W", symbol: "figure", color: .purple))
    #expect(weight.chart.style == .line)
    // A count of a type drawn as ranges is dots: a count has no lowest and highest.
    let count = try spec(
      #"{"version": 1, "display": {"name": "C"}, "series": [{"type": "HeartRate", "aggregation": "count"}]}"#
    )
    #expect(count.chart.style == .dots)
    #expect(count.valueUnit == .readings)
    // Ranges by bucket.
    for (bucket, range) in [
      ("week", CardRange.month), ("month", .sixMonths), ("hour", .week), ("day", .week),
    ] {
      let spec = try spec(
        #"{"version": 1, "display": {"name": "B"}, "series": [{"type": "Weight"}], "bucket": "\#(bucket)"}"#
      )
      #expect(spec.range == range, "\(bucket)")
    }
    // IDs by position.
    let ids = try spec(
      #"{"version": 1, "display": {"name": "I"}, "series": [{"type": "HeartRate"}, {"type": "RestingHeartRate"}, {"type": "WalkingHeartRateAverage"}], "formulas": [{"kind": "movingAverage", "of": "c"}], "chart": {"style": "line"}}"#
    )
    #expect(ids.series.map(\.id) == ["a", "b", "c"])
    #expect(ids.formulas.map(\.id) == ["f1"])
    #expect(ids.formulas[0].operation == .movingAverage(of: "c", points: 7))
  }

  @Test
  func namesAndLabelsAreTrimmed() throws {
    let spec = try spec(
      #"{"version": 1, "display": {"name": "　 Résumé \t"}, "series": [{"type": "HeartRate", "label": " Day "}]}"#
    )
    #expect(spec.display.name == "Résumé")
    #expect(spec.series[0].label == "Day")
  }

  @Test
  func leadAndUnits() throws {
    let spec = try spec(
      #"{"version": 1, "display": {"name": "L"}, "series": [{"type": "HeartRate", "hidden": true}, {"type": "RestingHeartRate"}]}"#
    )
    #expect(spec.lead == .series(spec.series[1]))
    #expect(spec.series[0].dataType?.name == "Heart Rate")
    #expect(spec.series[0].valueUnit.description == "count/min")
    #expect(CardValueUnit.readings.description == "count")
  }

  @Test
  func codableRoundTrip() throws {
    let spec = try spec(
      #"{"version": 1, "display": {"name": "Runs", "unit": null}, "series": [{"type": "HeartRate", "window": {"kind": "workout"}, "filter": {"deviceModels": ["Watch"]}, "label": "Run HR"}], "formulas": [{"kind": "movingAverage", "of": "a", "label": "Trend"}], "bucket": "day", "range": "M", "chart": {"style": "dots", "goal": {"value": 150.5}}}"#
    )
    let data = try JSONEncoder().encode(spec)
    #expect(try JSONDecoder().decode(CardSpec.self, from: data) == spec)
    #expect(try CardJSON(parsing: data) == spec.json)
    // Decoding validates.
    let invalid = Data(#"{"version": 2}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(CardSpec.self, from: invalid) }
  }

  @Test
  func everyWindowAndFormulaWritesItsFields() {
    #expect(CardSpec.Window.asleep.json.text() == #"{"kind":"asleep"}"#)
    #expect(
      CardSpec.Window.afterWaking(minutes: 30).json.text()
        == #"{"kind":"afterWaking","minutes":30}"#)
    #expect(
      CardSpec.Window.workout(activities: nil).json.text()
        == #"{"kind":"workout","activities":null}"#)
    #expect(CardSpec.Window.workout(activities: [37]).isSleep == false)
    #expect(CardSpec.Window.beforeSleep(minutes: 5).isSleep)
    #expect(
      CardSpec.Formula(id: "gap", operation: .difference(of: "a", minus: "b"), label: "Gap").json
        .text() == #"{"id":"gap","kind":"difference","of":["a","b"],"label":"Gap","hidden":false}"#)
    #expect(
      CardSpec.Filter(sources: ["s"]).json.text() == #"{"sources":["s"],"deviceModels":null}"#)
  }

  @Test
  func storedSpecsMustBeCanonical() throws {
    let canonical = try spec(
      #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate"}]}"#
    )
    .json
    #expect(CardSpec.storedErrors(canonical).isEmpty)
    // Values, not text: key order and number spelling don't matter.
    let reordered = try CardJSON(
      parsing: Data(
        #"{"chart": {"goal": null, "style": "ranges"}, "range": "W", "bucket": "auto", "formulas": [], "series": [{"hidden": false, "label": null, "filter": null, "window": null, "aggregation": "avg", "type": "HKQuantityTypeIdentifierHeartRate", "id": "a"}], "display": {"unit": null, "color": "red", "symbol": "heart.fill", "name": "HR"}, "version": 1.0}"#
          .utf8))
    #expect(CardSpec.storedErrors(reordered).isEmpty)
    let leftOut = CardSpec.storedErrors(
      try CardJSON(
        parsing: Data(
          #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate"}]}"#.utf8)))
    #expect(leftOut.map(\.code) == [.notCanonical])
    #expect(leftOut.first?.path == "")
  }

  @Test
  func theStoreAllows16KB() throws {
    let source = String(repeating: "s", count: 200)
    let filter =
      #"{"sources": [\#(Array(repeating: "\"\(source)\"", count: 10).joined(separator: ","))]}"#
    let series = Array(repeating: #"{"type": "HeartRate", "filter": \#(filter)}"#, count: 4)
    let text =
      #"{"version": 1, "display": {"name": "Big"}, "series": [\#(series.joined(separator: ","))], "chart": {"style": "dots"}}"#
    #expect(throws: CardSpecValidationError.self) { try CardSpec(inputJSON: Data(text.utf8)) }
    do {
      _ = try CardSpec(inputJSON: Data(text.utf8))
    } catch {
      #expect(error.errors.map(\.code) == [.tooLarge])
      #expect(error.errors[0].message.hasSuffix("the limit is 8 KB."))
    }
    let canonical = try CardSpecValidator.canonicalize(
      try CardJSON(parsing: Data(text.utf8)), sizeLimit: .max
    ).get()
    #expect(canonical.jsonText.utf8.count > HealthCards.maxSpecBytes)
    #expect(CardSpec.storedErrors(canonical.json).isEmpty)
  }

  @Test
  func invalidJSON() {
    #expect(
      throws: CardSpecValidationError([
        CardSpecError(path: "", code: .invalidJSON, message: "The spec isn't valid JSON.")
      ])
    ) {
      try CardSpec(inputJSON: Data("{".utf8))
    }
  }

  @Test
  func errorsListEveryOneALine() {
    let error = CardSpecValidationError([
      CardSpecError(path: "display.color", code: .unknownColor, message: "Bad color."),
      CardSpecError(path: "", code: .tooLarge, message: "Too large."),
    ])
    #expect(
      error.description == "The card spec has 2 errors:\n- display.color: Bad color.\n- Too large.")
  }
}
