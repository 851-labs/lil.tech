public import Foundation
public import SQLiteData

/// The kinds of notification Health records as category samples, each its type's identifier
/// (851-2829). Their pages list them, with what each said, from the sample's value and metadata.
public enum HealthNotificationKind: String, CaseIterable, Sendable {
  case highHeartRate = "HKCategoryTypeIdentifierHighHeartRateEvent"
  case lowHeartRate = "HKCategoryTypeIdentifierLowHeartRateEvent"
  case irregularRhythm = "HKCategoryTypeIdentifierIrregularHeartRhythmEvent"
  case lowCardioFitness = "HKCategoryTypeIdentifierLowCardioFitnessEvent"
  case hypertension = "HKCategoryTypeIdentifierHypertensionEvent"
  /// `HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent`, whose value is still the name of
  /// the identifier it replaced.
  case noise = "HKCategoryTypeIdentifierAudioExposureEvent"
  case headphone = "HKCategoryTypeIdentifierHeadphoneAudioExposureEvent"
  case walkingSteadiness = "HKCategoryTypeIdentifierAppleWalkingSteadinessEvent"
  case sleepApnea = "HKCategoryTypeIdentifierSleepApneaEvent"

  /// Whether its detail charts heart rate over the notification's period.
  public var chartsHeartRate: Bool { self == .highHeartRate || self == .lowHeartRate }
}

extension HealthDatabase {
  /// HealthKit's metadata keys for what notifications say, as the iPhone uploads them: the keys'
  /// raw values (`HKMetadataKeyHeartRateEventThreshold` is `HKHeartRateEventThreshold`).
  enum NotificationMetadataKey {
    static let heartRateThreshold = "HKHeartRateEventThreshold"
    static let vo2Max = "HKVO2MaxValue"
    static let cardioFitnessThreshold = "HKLowCardioFitnessEventThreshold"
    static let audioLevel = "HKAudioExposureLevel"
    static let audioDuration = "HKAudioExposureDuration"
  }

  /// A kind of notification, newest first, at most `limit`, with their provenance filled in so
  /// each can say which device it came from.
  public static func notifications(
    of kind: HealthNotificationKind, limit: Int, _ db: Database
  ) throws -> [HealthSample] {
    try HealthSample
      .where { $0.type.eq(kind.rawValue) }
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
      .withProvenance(db)
  }

  /// What a notification said, from its value and metadata: nil when it isn't a notification, or
  /// when what it needs is missing or not understood (an unknown value, metadata without the key).
  public static func notificationSummary(_ sample: HealthSample) -> HealthNotificationSummary? {
    guard let kind = HealthNotificationKind(rawValue: sample.type) else { return nil }
    let metadata = sample.metadataObject
    switch kind {
    case .highHeartRate, .lowHeartRate:
      guard
        let threshold = beatsPerMinute(metadata[NotificationMetadataKey.heartRateThreshold])
      else { return nil }
      return kind == .highHeartRate ? .heartRateAbove(threshold) : .heartRateBelow(threshold)
    case .lowCardioFitness:
      let vo2Max = quantity(metadata[NotificationMetadataKey.vo2Max])?.number
      let threshold = quantity(metadata[NotificationMetadataKey.cardioFitnessThreshold])?.number
      guard vo2Max != nil || threshold != nil else { return nil }
      return .cardioFitness(vo2Max: vo2Max, threshold: threshold)
    case .noise, .headphone:
      let level = quantity(metadata[NotificationMetadataKey.audioLevel])?.number
      let duration = seconds(metadata[NotificationMetadataKey.audioDuration])
      guard level != nil || duration != nil else { return nil }
      return .soundExposure(level: level, duration: duration)
    case .walkingSteadiness:
      return categoryValueName(sample.categoryValue, typeID: sample.type)
        .map(HealthNotificationSummary.walkingSteadiness)
    case .irregularRhythm, .sleepApnea, .hypertension:
      guard sample.endDate > sample.startDate else { return nil }
      return .period(DateInterval(start: sample.start, end: sample.end))
    }
  }

  /// A metadata quantity, as the iPhone writes one (its description: `"120 count/min"`), or a
  /// plain number: the number and its unit (empty for a plain number).
  static func quantity(_ value: Any?) -> (number: Double, unit: String)? {
    switch value {
    case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
      return number.doubleValue.isFinite ? (number.doubleValue, "") : nil
    case let string as String:
      let parts = string.split(separator: " ", maxSplits: 1)
      guard let first = parts.first, let number = Double(first), number.isFinite else {
        return nil
      }
      return (number, parts.count > 1 ? String(parts[1]) : "")
    default:
      return nil
    }
  }

  /// A heart rate quantity in beats per minute. Nil in a unit that isn't a rate of beats.
  static func beatsPerMinute(_ value: Any?) -> Double? {
    guard let (number, unit) = quantity(value) else { return nil }
    switch unit {
    case "", "count/min": return number
    case "count/s": return number * 60
    default: return nil
    }
  }

  /// A time quantity in seconds. Nil in a unit that isn't time.
  static func seconds(_ value: Any?) -> TimeInterval? {
    guard let (number, unit) = quantity(value) else { return nil }
    let scale: Double? = ["": 1, "s": 1, "ms": 0.001, "min": 60, "hr": 3600, "d": 86_400][unit]
    return scale.map { number * $0 }
  }
}

/// What a notification said, for its row and detail.
public enum HealthNotificationSummary: Equatable, Sendable {
  /// High heart rate: above this many BPM.
  case heartRateAbove(Double)
  /// Low heart rate: below this many BPM.
  case heartRateBelow(Double)
  /// Low cardio fitness: the VO₂ max and the threshold it was below, in mL/kg·min.
  case cardioFitness(vo2Max: Double?, threshold: Double?)
  /// Noise or headphone audio: the level in dB, for how many seconds.
  case soundExposure(level: Double?, duration: TimeInterval?)
  /// Walking steadiness, as Health names its value: "Low", "Still Very Low".
  case walkingSteadiness(String)
  /// Irregular rhythm, sleep apnea and hypertension: the period it was found in.
  case period(DateInterval)

  /// The line a notification's row shows: "Above 120 BPM", "92 dB for 4 min".
  public func line(calendar: Calendar) -> String {
    let locale = calendar.locale ?? .current
    func number(_ value: Double) -> String {
      value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }
    switch self {
    case .heartRateAbove(let threshold):
      return "Above \(Int(threshold.rounded())) BPM"
    case .heartRateBelow(let threshold):
      return "Below \(Int(threshold.rounded())) BPM"
    case .cardioFitness(let vo2Max?, let threshold?):
      return "\(number(vo2Max)) VO₂ max, below \(number(threshold))"
    case .cardioFitness(let vo2Max?, nil):
      return "\(number(vo2Max)) VO₂ max"
    case .cardioFitness(nil, let threshold?):
      return "Below \(number(threshold)) VO₂ max"
    case .cardioFitness(nil, nil):
      return ""
    case .soundExposure(let level?, let duration?):
      return "\(Int(level.rounded())) dB for \(Self.duration(duration))"
    case .soundExposure(let level?, nil):
      return "\(Int(level.rounded())) dB"
    case .soundExposure(nil, let duration?):
      return "For \(Self.duration(duration))"
    case .soundExposure(nil, nil):
      return ""
    case .walkingSteadiness(let name):
      return name
    case .period(let interval):
      let sameDay = calendar.isDate(interval.start, inSameDayAs: interval.end)
      return (interval.start..<interval.end).formatted(
        Date.IntervalFormatStyle(
          date: .abbreviated, time: sameDay ? .shortened : .omitted, locale: locale,
          calendar: calendar, timeZone: calendar.timeZone))
    }
  }

  /// "45 sec", "4 min", "1 hr 15 min".
  public static func duration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    guard total >= 60 else { return "\(total) sec" }
    let (hours, minutes) = (total / 3600, total % 3600 / 60)
    if hours == 0 { return "\(minutes) min" }
    return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
  }
}

extension HealthSample {
  /// Its metadata as an object, empty when it has none or it isn't one.
  var metadataObject: [String: Any] {
    guard let metadata,
      let object = try? JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any]
    else { return [:] }
    return object
  }
}
