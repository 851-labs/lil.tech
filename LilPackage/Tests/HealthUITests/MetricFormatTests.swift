import Foundation
import HealthUI
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
    #expect(MetricFormat.value(5_300, unit: "m", typeID: "x").unit == "km")
    #expect(MetricFormat.value(420, unit: "m", typeID: "x").unit == "m")
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
}
