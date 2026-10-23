import Foundation
import HealthPages
import Testing

struct MetricFormatTests {
  private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
  // 2025-10-15 12:00 UTC, a Wednesday.
  private let now = Date(timeIntervalSince1970: 1_760_529_600)

  @Test
  func valuesInHealthsUnits() {
    let steps = MetricFormat.value(8214, unit: "count", typeID: "HKQuantityTypeIdentifierStepCount")
    #expect(steps.unit == "steps")
    #expect(steps.number == 8214.formatted(.number.precision(.fractionLength(0))))
    #expect(MetricFormat.value(0.97, unit: "%", typeID: "x").unit == "%")
    #expect(MetricFormat.value(0.97, unit: "%", typeID: "x").number == 97.formatted())
    #expect(MetricFormat.value(62, unit: "count/min", typeID: "x").unit == "BPM")
    // Whole numbers for BPM, as Health shows them; decimals for small values otherwise.
    #expect(MetricFormat.value(56.6, unit: "count/min", typeID: "x").number == 57.formatted())
    #expect(MetricFormat.value(4.51, unit: "L", typeID: "x").number == 4.51.formatted())
    let respiratory = "HKQuantityTypeIdentifierRespiratoryRate"
    #expect(
      MetricFormat.value(15.5, unit: "count/min", typeID: respiratory).number == 15.5.formatted())
    #expect(
      MetricFormat.value(
        15, unit: "count/min", typeID: "HKQuantityTypeIdentifierRespiratoryRate"
      ).unit == "breaths/min")
    // A distance covered is in km whatever its length, as in Health; a length stays in metres.
    let distance = "HKQuantityTypeIdentifierDistanceWalkingRunning"
    #expect(MetricFormat.value(5_300, unit: "m", typeID: distance) == (5.3.formatted(), "km"))
    #expect(MetricFormat.value(420, unit: "m", typeID: distance) == (0.42.formatted(), "km"))
    let sixMinuteWalk = "HKQuantityTypeIdentifierSixMinuteWalkTestDistance"
    #expect(MetricFormat.value(1_020, unit: "m", typeID: sixMinuteWalk).unit == "m")
    #expect(
      MetricFormat.value(1.78, unit: "m", typeID: "HKQuantityTypeIdentifierHeight").unit == "m")
    #expect(MetricFormat.value(36.6, unit: "degC", typeID: "x").unit == "°C")
    let cadence = "HKQuantityTypeIdentifierCyclingCadence"
    #expect(MetricFormat.value(85, unit: "count/min", typeID: cadence).unit == "RPM")
    let swimming = "HKQuantityTypeIdentifierDistanceSwimming"
    #expect(MetricFormat.value(1_500, unit: "m", typeID: swimming).unit == "m")
    let walking = "HKQuantityTypeIdentifierWalkingSpeed"
    #expect(MetricFormat.value(1.2, unit: "m/s", typeID: walking).unit == "km/h")
    let stairs = "HKQuantityTypeIdentifierStairAscentSpeed"
    #expect(MetricFormat.value(0.5, unit: "m/s", typeID: stairs).unit == "m/s")
    #expect(MetricFormat.value(1, unit: "mg/dL", typeID: "x").unit == "mg/dL")
    let cardioFitness = "HKQuantityTypeIdentifierVO2Max"
    #expect(MetricFormat.value(41.2, unit: "ml/(kg*min)", typeID: cardioFitness).unit == "VO₂ max")
  }

  /// Charts plot values in the header's unit (851-3105), so their axes read as it does.
  @Test
  func displayUnitsConvertStoredValues() {
    let walking = MetricFormat.unit("m/s", typeID: "HKQuantityTypeIdentifierWalkingSpeed")
    #expect(walking.label == "km/h")
    #expect(walking.convert(1.25) == 4.5)
    #expect(walking.format(walking.convert(1.25)) == 4.5.formatted())
    let stairs = MetricFormat.unit("m/s", typeID: "HKQuantityTypeIdentifierStairAscentSpeed")
    #expect(stairs.convert(0.5) == 0.5)
    let distance = MetricFormat.unit("m", typeID: "HKQuantityTypeIdentifierDistanceCycling")
    #expect(distance.convert(12_500) == 12.5)
    let swimming = MetricFormat.unit("m", typeID: "HKQuantityTypeIdentifierDistanceSwimming")
    #expect(swimming == MetricFormat.unit("m", typeID: "HKQuantityTypeIdentifierHeight"))
    #expect(MetricFormat.unit("%", typeID: "x").convert(0.22) == 22)
    #expect(MetricFormat.unit("kg", typeID: "x").convert(71.4) == 71.4)
  }

  @Test
  func datesLikeHealth() {
    let date = { (daysAgo: Double) in self.now.addingTimeInterval(-daysAgo * 86_400) }
    let style = Date.FormatStyle(calendar: utc, timeZone: utc.timeZone)
    #expect(MetricFormat.date(date(0), isDay: true, now: now, calendar: utc) == "Today")
    #expect(MetricFormat.date(date(0), isDay: false, now: now, calendar: utc) != "Today")
    #expect(MetricFormat.date(date(1), isDay: true, now: now, calendar: utc) == "Yesterday")
    #expect(
      MetricFormat.date(date(3), isDay: true, now: now, calendar: utc)
        == date(3).formatted(style.weekday(.wide)))
    #expect(
      MetricFormat.date(date(30), isDay: true, now: now, calendar: utc)
        == date(30).formatted(style.month(.abbreviated).day()))
    #expect(
      MetricFormat.date(date(400), isDay: true, now: now, calendar: utc)
        == date(400).formatted(style.month(.abbreviated).day().year()))
  }

  @Test
  func durationsReadAsSessionsDo() {
    #expect(MetricFormat.duration(23.4) == ("23", "sec"))
    // Rounded before choosing the unit.
    #expect(MetricFormat.duration(59.7) == ("1", "min"))
    #expect(MetricFormat.duration(150) == ("2.5", "min"))
  }
}
