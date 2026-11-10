import Foundation

/// How lil health reads a metadata key's value (851-4170): one table, `kinds`, of each HealthKit
/// key the Health tools and cards read and what kind of value it holds (text, a number, a
/// Boolean, an enum's case, a workout activity, or a quantity and the unit it's read in), which
/// the `samples` and `workout` tools, the workout pages and the cards' workout windows read
/// through `value(_:in:)`. Every key in it is one lil health keeps (`keptMetadataKeys`, 851-4152).
/// The server reads them alike (`Services/api/src/health/MetadataValues.ts`), so the tools agree
/// (the conformance cases).
///
/// Quantities come in two forms, which both read (851-4150): iPhones since 851-4150 write an
/// `HKQuantity` whole, `{ "value": 84.6, "unit": "m" }` in its key's unit
/// (`HealthCatalog.metadataQuantityUnits`), and earlier ones (and records they uploaded) as its
/// description, a number with 6 significant digits and a unit ("8460 cm", "120 count/min"),
/// rounded to that. A unit not listed here gives nil. Dates likewise: `{ "date": "…Z" }`, ISO
/// 8601, or Unix milliseconds before (`HealthEncoder.json`).
public enum HealthMetadataValues {
  /// What a metadata key's value is.
  public enum Kind: Sendable {
    case text
    case number
    case boolean
    /// An enum, by its raw value: each case's name, nil for those that say nothing.
    case named([String?])
    /// An `HKWorkoutActivityType`'s raw value, read as the activity's name.
    case activity
    case quantity(Quantity)
    /// A date, read as Unix milliseconds.
    case date
  }

  /// A value as its kind reads it.
  public enum Value: Equatable, Sendable {
    case text(String)
    case number(Double)
    case boolean(Bool)

    public var string: String? {
      if case .text(let value) = self { value } else { nil }
    }

    public var double: Double? {
      if case .number(let value) = self { value } else { nil }
    }

    public var bool: Bool? {
      if case .boolean(let value) = self { value } else { nil }
    }
  }

  /// What a quantity measures: the unit it's read in (`unit`), and each unit (`HKUnit`'s unit
  /// strings, as `HKQuantity.description` and `unitString` write them) it's converted from
  /// (`conversions`), with a percent's number from 0 to 100, as descriptions write it.
  public enum Quantity: Sendable, CaseIterable {
    case length, speed, mets, temperature, humidity, heartRate, duration, soundLevel, vo2Max
    case illuminance

    public var unit: String {
      switch self {
      case .length: "m"
      case .speed: "m/s"
      case .mets: "kcal/hr·kg"
      case .temperature: "degC"
      case .humidity: "%"
      case .heartRate: "count/min"
      case .duration: "s"
      case .soundLevel: "dBASPL"
      case .vo2Max: "mL/kg·min"
      case .illuminance: "lx"
      }
    }

    /// Its `conversions`, made once.
    static let conversionsByQuantity = Dictionary(
      uniqueKeysWithValues: allCases.map { ($0, $0.makeConversions()) })

    var conversions: [String: @Sendable (Double) -> Double] {
      // Every case is in it: it's made from `allCases`.
      Self.conversionsByQuantity[self]!
    }

    private func makeConversions() -> [String: @Sendable (Double) -> Double] {
      switch self {
      case .length:
        Self.scaled([
          "mm": 0.001, "cm": 0.01, "m": 1, "km": 1000, "in": 0.0254, "ft": 0.3048, "yd": 0.9144,
          "mi": 1609.344,
        ])
      case .speed:
        Self.scaled(["m/s": 1, "km/hr": 1000 / 3600, "mi/hr": 1609.344 / 3600, "ft/s": 0.3048])
      // METs: `kcal/hr·kg`, as `HKQuantity.description` writes the unit (with a middle dot).
      case .mets: Self.scaled(["kcal/hr·kg": 1, "kcal/(kg·hr)": 1, "kcal/(hr·kg)": 1])
      case .temperature: ["degC": { $0 }, "degF": { ($0 - 32) * 5 / 9 }, "K": { $0 - 273.15 }]
      // A percent, from 0 to 100. Apple's Workout app writes humidity 100 times too large (a
      // quantity of 72 percent units for 72%, described as "7200 %"), so a value over 100 is
      // divided by 100.
      case .humidity: ["%": { $0 > 100 ? $0 / 100 : $0 }]
      case .heartRate: Self.scaled(["count/min": 1, "count/s": 60])
      case .duration: Self.scaled(["ms": 0.001, "s": 1, "min": 60, "hr": 3600, "d": 86400])
      case .soundLevel: Self.scaled(["dBASPL": 1])
      // VO2 max, in mL/(kg·min): `HKQuantity` writes the unit `mL/min·kg`.
      case .vo2Max:
        Self.scaled(["mL/min·kg": 1, "mL/kg·min": 1, "ml/min·kg": 1, "ml/kg·min": 1])
      case .illuminance: Self.scaled(["lx": 1, "klx": 1000])
      }
    }

    /// Each unit's function: multiplying by its factor.
    private static func scaled(_ factors: [String: Double]) -> [String:
      @Sendable (Double) -> Double]
    {
      factors.mapValues { factor in { $0 * factor } }
    }
  }

  static let heartRateTestTypes: [String?] = [
    nil, "maxExercise", "predictionSubMaxExercise", "predictionNonExercise",
  ]

  /// `HKWorkoutSwimmingLocationType`'s cases, by raw value; 0 (unknown) is nil.
  public static let swimmingLocations: [String?] = [nil, "pool", "openWater"]

  /// Each metadata key the Health tools and cards read, and what kind of value it holds.
  public static let kinds: [String: Kind] = [
    // Samples (851-4166)
    "HKWasUserEntered": .boolean,
    "HKTimeZone": .text,
    "HKFoodType": .text,
    "HKMetadataKeyHeartRateMotionContext": .named([nil, "sedentary", "active"]),
    "HKMetadataKeyUserMotionContext": .named([nil, "stationary", "active"]),
    "HKHeartRateSensorLocation": .named([
      "other", "chest", "wrist", "finger", "hand", "earLobe", "foot",
    ]),
    "HKBodyTemperatureSensorLocation": .named([
      "other", "armpit", "body", "ear", "finger", "gastroIntestinal", "mouth", "rectum", "toe",
      "earDrum", "temporalArtery", "forehead",
    ]),
    "HKBloodGlucoseMealTime": .named([nil, "preprandial", "postprandial"]),
    "HKInsulinDeliveryReason": .named([nil, "basal", "bolus"]),
    "HKVO2MaxTestType": .named(heartRateTestTypes + ["predictionStepTest"]),
    "HKVO2MaxValue": .quantity(.vo2Max),
    "HKLowCardioFitnessEventThreshold": .quantity(.vo2Max),
    "HKHeartRateEventThreshold": .quantity(.heartRate),
    "HKMetadataKeyHeartRateRecoveryTestType": .named(heartRateTestTypes + ["stepTest"]),
    "HKMetadataKeyHeartRateRecoveryActivityType": .activity,
    "HKMetadataKeyHeartRateRecoveryActivityDuration": .quantity(.duration),
    "HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate": .quantity(.heartRate),
    "HKMetadataKeyAudioExposureLevel": .quantity(.soundLevel),
    "HKMetadataKeyAudioExposureDuration": .quantity(.duration),
    "HKMetadataKeyHeadphoneGain": .quantity(.soundLevel),
    "HKPhysicalEffortEstimationType": .named([nil, "activityLookup", "deviceSensed"]),
    "HKActivityType": .activity,
    "HKMetadataKeyDevicePlacementSide": .named([nil, "left", "right", "central"]),
    "HKMetadataKeyAppleDeviceCalibrated": .boolean,
    "HKAlgorithmVersion": .number,
    "HKDateOfEarliestDataUsedForEstimate": .date,
    "HKMetadataKeyQuantityClampedToLowerBound": .boolean,
    "HKMetadataKeyQuantityClampedToUpperBound": .boolean,
    "HKReferenceRangeLowerLimit": .number,
    "HKReferenceRangeUpperLimit": .number,
    "HKWasTakenInLab": .boolean,
    "HKMetadataKeyWaterSalinity": .named([nil, "freshWater", "saltWater"]),
    "HKMetadataKeyMaximumLightIntensity": .quantity(.illuminance),
    "HKMenstrualCycleStart": .boolean,
    "HKSexualActivityProtectionUsed": .boolean,
    "HKDeviceName": .text,
    "HKDeviceManufacturerName": .text,
    // Workouts, their activities and events (851-4015, 851-4165)
    "HKIndoorWorkout": .boolean,
    "HKSwimmingLocationType": .named(swimmingLocations),
    "HKWorkoutBrandName": .text,
    "HKElevationAscended": .quantity(.length),
    "HKElevationDescended": .quantity(.length),
    "HKAverageSpeed": .quantity(.speed),
    "HKMaximumSpeed": .quantity(.speed),
    "HKAverageMETs": .quantity(.mets),
    "HKLapLength": .quantity(.length),
    "HKSWOLFScore": .number,
    // `HKWeatherCondition`'s cases, without their prefix; 0 (none) is nil.
    "HKWeatherCondition": .named([
      nil, "clear", "fair", "partlyCloudy", "mostlyCloudy", "cloudy", "foggy", "haze", "windy",
      "blustery", "smoky", "dust", "snow", "hail", "sleet", "freezingDrizzle", "freezingRain",
      "mixedRainAndHail", "mixedRainAndSnow", "mixedRainAndSleet", "mixedSnowAndSleet",
      "drizzle", "scatteredShowers", "showers", "thunderstorms", "tropicalStorm", "hurricane",
      "tornado",
    ]),
    "HKWeatherTemperature": .quantity(.temperature),
    "HKWeatherHumidity": .quantity(.humidity),
    // `HKSwimmingStrokeStyle`'s cases; 0 (unknown) is nil.
    "HKSwimmingStrokeStyle": .named([
      nil, "mixed", "freestyle", "backstroke", "breaststroke", "butterfly", "kickboard",
    ]),
  ]

  /// What `metadata` says at `key`, read as the key's kind (`kinds`), or nil if it doesn't say.
  /// A key that isn't in `kinds` is never read.
  public static func value(_ key: String, in metadata: [String: Any]?) -> Value? {
    guard let kind = kinds[key] else { return nil }
    return read(kind, metadata?[key])
  }

  /// The type a value of `kind` is read as: `Bool`, `Double` or `String`.
  public static func valueType(of kind: Kind) -> Any.Type {
    switch kind {
    case .boolean: Bool.self
    case .number, .quantity, .date: Double.self
    case .text, .named, .activity: String.self
    }
  }

  /// A value of `kind`, or nil if it isn't one.
  public static func read(_ kind: Kind, _ value: Any?) -> Value? {
    switch kind {
    case .text: text(value).map(Value.text)
    case .number: number(value).map(Value.number)
    case .boolean: boolean(value).map(Value.boolean)
    case .named(let cases): named(cases, value).map(Value.text)
    case .activity: activityName(value).map(Value.text)
    case .quantity(let quantity): self.quantity(quantity, value).map(Value.number)
    case .date: date(value).map(Value.number)
    }
  }

  // MARK: - Reading values

  /// A string unless it's blank: only spaces, tabs and line breaks, as on the server.
  public static func text(_ value: Any?) -> String? {
    guard let string = value as? String,
      !string.unicodeScalars.allSatisfy({ " \t\n\r".unicodeScalars.contains($0) })
    else { return nil }
    return string
  }

  /// Whether it's a JSON Boolean, which `JSONSerialization` makes an `NSNumber` too.
  static func isBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  /// A JSON number, not a Boolean.
  public static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, !isBoolean(number), number.doubleValue.isFinite
    else { return nil }
    return number.doubleValue
  }

  /// A Boolean, or 0 or 1 from apps that write it as a number (`HKIndoorWorkout`, for one).
  public static func boolean(_ value: Any?) -> Bool? {
    if isBoolean(value), let number = value as? NSNumber { return number.boolValue }
    switch number(value) {
    case 1: return true
    case 0: return false
    default: return nil
    }
  }

  /// The case at an enum's raw value, if it's a whole number with one (not set is nil).
  public static func named(_ cases: [String?], _ value: Any?) -> String? {
    guard let raw = number(value), raw >= 0, raw.rounded() == raw, raw < Double(cases.count)
    else { return nil }
    return cases[Int(raw)]
  }

  /// A workout activity's name, by its `HKWorkoutActivityType` raw value.
  static func activityName(_ value: Any?) -> String? {
    // Whole and below 10^15, so it makes an `Int`, as on the server.
    guard let raw = number(value), raw.rounded() == raw, abs(raw) < 1e15 else { return nil }
    return HealthCatalog.workoutActivityName(Int(raw))
  }

  /// A number and a unit, as `HKQuantity.description` writes them: "120 count/min", "4250 cm".
  nonisolated(unsafe) static let quantityText =
    /([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?) (\S+)/

  /// A metadata quantity's number and unit, in either form: `{ "value": 0.72, "unit": "%" }`, as
  /// the iPhone writes one since 851-4150, or its description, "72 %", as before. A percent's
  /// number is from 0 to 100, as a description writes it, so a fraction (`HKUnit`'s percent) is
  /// multiplied by 100, to 12 significant digits. Nil for anything else.
  public static func quantityParts(_ value: Any?) -> (number: Double, unit: String)? {
    if let description = value as? String {
      guard let match = description.wholeMatch(of: quantityText), let number = Double(match.1)
      else { return nil }
      return (number, String(match.2))
    }
    guard let object = value as? [String: Any], let number = number(object["value"]),
      let unit = object["unit"] as? String
    else { return nil }
    guard unit == "%" else { return (number, unit) }
    // To 12 significant digits, as the iPhone writes values, without the multiplication's noise
    // (0.555 is 55.5, not 55.50000000000001), as the server does (`toPrecision(12)`).
    return (Double(String(format: "%.12g", number * 100)) ?? number * 100, unit)
  }

  /// A quantity in `quantity`'s unit, or nil in a unit it isn't read in.
  public static func quantity(_ quantity: Quantity, _ value: Any?) -> Double? {
    guard let (number, unit) = quantityParts(value), let convert = quantity.conversions[unit]
    else { return nil }
    let converted = convert(number)
    return converted.isFinite ? converted : nil
  }

  /// An ISO 8601 date and time with its zone, to the second or the millisecond, as the iPhone
  /// writes a date: "2026-10-12T00:00:00.000Z".
  nonisolated(unsafe) static let isoDateText =
    /[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,3})?(?:Z|[+-][0-9]{2}:[0-9]{2})/

  /// A date as Unix milliseconds, in either form: `{ "date": "2026-10-12T00:00:00.000Z" }`, as the
  /// iPhone writes one since 851-4150, or Unix milliseconds, as before.
  public static func date(_ value: Any?) -> Double? {
    if let milliseconds = number(value) { return milliseconds }
    guard let object = value as? [String: Any], let text = object["date"] as? String,
      text.wholeMatch(of: isoDateText) != nil,
      let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
        ?? (try? Date.ISO8601FormatStyle().parse(text))
    else { return nil }
    return (date.timeIntervalSince1970 * 1000).rounded()
  }
}
