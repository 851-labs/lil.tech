import Foundation
import HealthPages
import Testing

/// en_US's formats, with metric units, as the snapshot catalogs use.
private let metric = Locale(identifier: "en_US@measure=metric")
private let us = Locale(identifier: "en_US")
private let uk = Locale(identifier: "en_GB")

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
    let steps = MetricFormat.value(
      8214, unit: "count", typeID: "HKQuantityTypeIdentifierStepCount", locale: metric)
    #expect(steps.unit == "steps")
    #expect(steps.number == "8,214")
    #expect(MetricFormat.value(0.97, unit: "%", typeID: "x", locale: metric).unit == "%")
    #expect(
      MetricFormat.value(0.97, unit: "%", typeID: "x", locale: metric).number == "97")
    #expect(MetricFormat.value(62, unit: "count/min", typeID: "x", locale: metric).unit == "BPM")
    // Whole numbers for BPM, as Health shows them; decimals for small values otherwise.
    #expect(
      MetricFormat.value(56.6, unit: "count/min", typeID: "x", locale: metric).number
        == "57")
    #expect(
      MetricFormat.value(4.51, unit: "L", typeID: "x", locale: metric).number == "4.51")
    let respiratory = "HKQuantityTypeIdentifierRespiratoryRate"
    #expect(
      MetricFormat.value(15.5, unit: "count/min", typeID: respiratory, locale: metric).number
        == "15.5")
    #expect(
      MetricFormat.value(
        15, unit: "count/min", typeID: "HKQuantityTypeIdentifierRespiratoryRate", locale: metric
      ).unit == "breaths/min")
    // A distance covered is in km whatever its length, as in Health; a length stays in metres.
    let distance = "HKQuantityTypeIdentifierDistanceWalkingRunning"
    #expect(
      MetricFormat.value(5_300, unit: "m", typeID: distance, locale: metric) == (
        "5.3", "km"
      ))
    #expect(
      MetricFormat.value(420, unit: "m", typeID: distance, locale: metric) == (
        "0.42", "km"
      ))
    // To the metre under 1 km, so a short sample isn't 0.
    #expect(
      MetricFormat.value(4, unit: "m", typeID: distance, locale: metric).number == "0.004"
    )
    let sixMinuteWalk = "HKQuantityTypeIdentifierSixMinuteWalkTestDistance"
    #expect(MetricFormat.value(1_020, unit: "m", typeID: sixMinuteWalk, locale: metric).unit == "m")
    // Height, waist and a step in cm, as Health shows them (851-3116).
    #expect(
      MetricFormat.value(1.78, unit: "m", typeID: "HKQuantityTypeIdentifierHeight", locale: metric)
        == ("178", "cm"))
    let stepLength = "HKQuantityTypeIdentifierWalkingStepLength"
    #expect(MetricFormat.value(0.724, unit: "m", typeID: stepLength, locale: metric).unit == "cm")
    #expect(MetricFormat.value(36.6, unit: "degC", typeID: "x", locale: metric).unit == "°C")
    let cadence = "HKQuantityTypeIdentifierCyclingCadence"
    #expect(
      MetricFormat.value(85, unit: "count/min", typeID: cadence, locale: metric).unit == "RPM")
    let swimming = "HKQuantityTypeIdentifierDistanceSwimming"
    #expect(MetricFormat.value(1_500, unit: "m", typeID: swimming, locale: metric).unit == "m")
    let walking = "HKQuantityTypeIdentifierWalkingSpeed"
    #expect(MetricFormat.value(1.2, unit: "m/s", typeID: walking, locale: metric).unit == "km/h")
    let stairs = "HKQuantityTypeIdentifierStairAscentSpeed"
    #expect(MetricFormat.value(0.5, unit: "m/s", typeID: stairs, locale: metric).unit == "m/s")
    #expect(MetricFormat.value(1, unit: "mg/dL", typeID: "x", locale: metric).unit == "mg/dL")
    let cardioFitness = "HKQuantityTypeIdentifierVO2Max"
    #expect(
      MetricFormat.value(41.2, unit: "ml/(kg*min)", typeID: cardioFitness, locale: metric).unit
        == "VO₂ max")
  }

  /// Charts plot values in the header's unit (851-3105), so their axes read as it does.
  @Test
  func displayUnitsConvertStoredValues() {
    let walking = MetricFormat.unit(
      "m/s", typeID: "HKQuantityTypeIdentifierWalkingSpeed", locale: metric)
    #expect(walking.label == "km/h")
    #expect(walking.convert(1.25) == 4.5)
    #expect(walking.format(walking.convert(1.25)) == "4.5")
    let stairs = MetricFormat.unit(
      "m/s", typeID: "HKQuantityTypeIdentifierStairAscentSpeed", locale: metric)
    #expect(stairs.convert(0.5) == 0.5)
    let distance = MetricFormat.unit(
      "m", typeID: "HKQuantityTypeIdentifierDistanceCycling", locale: metric)
    #expect(distance.convert(12_500) == 12.5)
    let swimming = MetricFormat.unit(
      "m", typeID: "HKQuantityTypeIdentifierDistanceSwimming", locale: metric)
    #expect(swimming == MetricFormat.unit("m", typeID: "x", locale: metric))
    #expect(MetricFormat.unit("%", typeID: "x", locale: metric).convert(0.22) == 22)
    #expect(MetricFormat.unit("kg", typeID: "x", locale: metric).convert(71.4) == 71.4)
  }

  /// In the locale's preferred units, as Health shows them (851-3116): the US's miles, mph,
  /// pounds, °F, feet and inches, and fluid ounces.
  @Test
  func usUnits() {
    let distance = "HKQuantityTypeIdentifierDistanceWalkingRunning"
    #expect(
      MetricFormat.value(5_300, unit: "m", typeID: distance, locale: us) == ("3.29", "mi")
    )
    // To the thousandth under a mile, as for km.
    #expect(
      MetricFormat.value(400, unit: "m", typeID: distance, locale: us).number == "0.249")
    let swimming = "HKQuantityTypeIdentifierDistanceSwimming"
    #expect(
      MetricFormat.value(914.4, unit: "m", typeID: swimming, locale: us) == (
        "1,000", "yd"
      ))
    let walking = "HKQuantityTypeIdentifierWalkingSpeed"
    #expect(
      MetricFormat.value(1.341, unit: "m/s", typeID: walking, locale: us) == ("3", "mph"))
    let stairs = "HKQuantityTypeIdentifierStairAscentSpeed"
    #expect(
      MetricFormat.value(0.6096, unit: "m/s", typeID: stairs, locale: us) == ("2", "ft/s")
    )
    // Pounds and °F keep a decimal from 100, so a weight's change and a fever show.
    let weight = "HKQuantityTypeIdentifierBodyMass"
    #expect(
      MetricFormat.value(71.4, unit: "kg", typeID: weight, locale: us) == ("157.4", "lb"))
    let temperature = "HKQuantityTypeIdentifierBodyTemperature"
    #expect(
      MetricFormat.value(37, unit: "degC", typeID: temperature, locale: us) == (
        "98.6", "°F"
      ))
    #expect(
      MetricFormat.value(38, unit: "degC", typeID: temperature, locale: us) == (
        "100.4", "°F"
      ))
    let height = "HKQuantityTypeIdentifierHeight"
    #expect(MetricFormat.value(1.803, unit: "m", typeID: height, locale: us) == ("5′ 11″", ""))
    #expect(MetricFormat.value(1.8288, unit: "m", typeID: height, locale: us) == ("6′", ""))
    let waist = "HKQuantityTypeIdentifierWaistCircumference"
    #expect(
      MetricFormat.value(0.8128, unit: "m", typeID: waist, locale: us) == ("32", "in"))
    let oscillation = "HKQuantityTypeIdentifierRunningVerticalOscillation"
    #expect(MetricFormat.value(7.62, unit: "cm", typeID: oscillation, locale: us).unit == "in")
    let depth = "HKQuantityTypeIdentifierUnderwaterDepth"
    #expect(
      MetricFormat.value(3.048, unit: "m", typeID: depth, locale: us) == ("10", "ft"))
    let water = "HKQuantityTypeIdentifierDietaryWater"
    #expect(
      MetricFormat.value(500, unit: "mL", typeID: water, locale: us) == ("16.9", "fl oz"))
    // What has no other unit in the US stays: kcal, grams, litres.
    #expect(MetricFormat.value(250, unit: "kcal", typeID: "x", locale: us).unit == "kcal")
    #expect(MetricFormat.value(30, unit: "g", typeID: "x", locale: us).unit == "g")
    #expect(MetricFormat.value(4.51, unit: "L", typeID: "x", locale: us).unit == "L")
  }

  /// The UK's: miles and mph, stones and pounds, °C, and millilitres.
  @Test
  func ukUnits() {
    let distance = "HKQuantityTypeIdentifierDistanceCycling"
    #expect(
      MetricFormat.value(16_093.44, unit: "m", typeID: distance, locale: uk) == (
        "10", "mi"
      ))
    let weight = "HKQuantityTypeIdentifierBodyMass"
    // 11 st 4 lb is 158 lb.
    #expect(
      MetricFormat.value(71.668, unit: "kg", typeID: weight, locale: uk) == ("11 st 4 lb", ""))
    #expect(MetricFormat.value(69.853, unit: "kg", typeID: weight, locale: uk) == ("11 st", ""))
    #expect(MetricFormat.value(37, unit: "degC", typeID: "x", locale: uk) == ("37", "°C"))
    let water = "HKQuantityTypeIdentifierDietaryWater"
    #expect(MetricFormat.value(500, unit: "mL", typeID: water, locale: uk).unit == "mL")
    let height = "HKQuantityTypeIdentifierHeight"
    #expect(MetricFormat.value(1.803, unit: "m", typeID: height, locale: uk).number == "5′ 11″")
  }

  /// The Mac's Language & Region settings: a measurement system and a temperature unit of their
  /// own, whatever the region's.
  @Test
  func unitsFollowTheLocalesSettings() {
    let temperature = "HKQuantityTypeIdentifierBodyTemperature"
    // The US, set to metric and Celsius.
    let metricUS = Locale(identifier: "en_US@measure=metric;mu=celsius")
    #expect(MetricFormat.unit("degC", typeID: temperature, locale: metricUS).label == "°C")
    #expect(MetricFormat.unit("kg", typeID: "x", locale: metricUS).label == "kg")
    // Germany, in Fahrenheit.
    let fahrenheitDE = Locale(identifier: "de_DE@mu=fahrenhe")
    #expect(MetricFormat.unit("degC", typeID: temperature, locale: fahrenheitDE).label == "°F")
    #expect(MetricFormat.unit("kg", typeID: "x", locale: fahrenheitDE).label == "kg")
  }

  /// Numbers are written in the locale the unit is for, whatever the Mac's.
  @Test
  func numbersInTheLocale() {
    let germany = Locale(identifier: "de_DE")
    let distance = "HKQuantityTypeIdentifierDistanceWalkingRunning"
    #expect(
      MetricFormat.value(5_300, unit: "m", typeID: distance, locale: germany) == ("5,3", "km"))
    // Arabic writes °F in its own script: still Fahrenheit.
    let arabic = Locale(identifier: "ar_SA@mu=fahrenhe")
    #expect(MetricFormat.unit("degC", typeID: "x", locale: arabic).label == "°F")
  }

  /// A compound unit's axis ticks fall on whole inches or pounds, at most 5 of them.
  @Test
  func compoundTicks() {
    let height = MetricFormat.unit("m", typeID: "HKQuantityTypeIdentifierHeight", locale: us)
    #expect(height.compoundTickStride(over: 3) == 1)
    #expect(height.compoundTickStride(over: 79) == 24)
    let weight = MetricFormat.unit("kg", typeID: "x", locale: uk)
    #expect(weight.compoundTickStride(over: 230) == 70)
    #expect(MetricFormat.unit("kg", typeID: "x", locale: us).compoundTickStride(over: 230) == nil)
    #expect(height.format(.nan) == "NaN")
  }

  /// Charts plot converted values, so a °F axis is offset as well as scaled.
  @Test
  func convertingTemperatures() {
    let fahrenheit = MetricFormat.unit("degC", typeID: "x", locale: us)
    #expect(fahrenheit.convert(0) == 32)
    #expect(fahrenheit.convert(100) == 212)
    let inches = MetricFormat.unit("m", typeID: "HKQuantityTypeIdentifierHeight", locale: us)
    // An axis's ticks, in inches, read as the header does.
    #expect(inches.format(70) == "5′ 10″")
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
