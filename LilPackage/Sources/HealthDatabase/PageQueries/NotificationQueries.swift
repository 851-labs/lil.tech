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

  /// Whether it's listed (and grouped, and dated) by its end rather than its start: sleep apnea
  /// and hypertension, whose samples are the 30 days evaluated, and arrive at their end. A
  /// judgment call: where Health itself places them isn't verified.
  public var listedByEnd: Bool { self == .sleepApnea || self == .hypertension }

  /// The date `sample` is listed under.
  public func listedDate(of sample: HealthSample) -> Date {
    listedByEnd ? sample.end : sample.start
  }
}

/// A notification with what it said, worked out once rather than on every render.
public struct HealthNotification: Equatable, Identifiable, Sendable {
  public var sample: HealthSample
  public var summary: HealthNotificationSummary?

  public init(_ sample: HealthSample) {
    self.sample = sample
    summary = HealthDatabase.notificationSummary(sample)
  }

  public var id: String { sample.id }
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

  /// A kind of notification, newest first by the date it's listed under (`listedByEnd`), at
  /// most `limit`, with their provenance filled in so each can say which device it came from.
  /// The limit takes the latest by start; kinds listed by their end are then put in that order.
  public static func notifications(
    of kind: HealthNotificationKind, limit: Int, _ db: Database
  ) throws -> [HealthNotification] {
    var samples = try samplePage(of: kind.rawValue, after: nil, limit: limit, db)
    if kind.listedByEnd {
      samples.sort { ($0.endDate, $0.id) > ($1.endDate, $1.id) }
    }
    return samples.map(HealthNotification.init)
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
      let threshold = quantity(metadata[NotificationMetadataKey.cardioFitnessThreshold])?.number
      if let vo2Max = quantity(metadata[NotificationMetadataKey.vo2Max])?.number {
        return .cardioFitness(vo2Max: vo2Max, threshold: threshold)
      }
      return threshold.map(HealthNotificationSummary.cardioFitnessThreshold)
    case .noise, .headphone:
      let duration = seconds(metadata[NotificationMetadataKey.audioDuration])
      if let level = quantity(metadata[NotificationMetadataKey.audioLevel])?.number {
        return .soundExposure(level: level, duration: duration)
      }
      return duration.map(HealthNotificationSummary.soundDuration)
    case .walkingSteadiness:
      return categoryValueName(sample.categoryValue, typeID: sample.type)
        .map(HealthNotificationSummary.walkingSteadiness)
    case .irregularRhythm, .sleepApnea, .hypertension:
      guard sample.endDate > sample.startDate else { return nil }
      return .period(DateInterval(start: sample.start, end: sample.end))
    }
  }

  /// A metadata quantity, as the iPhone writes one (its description: `"120 count/min"`), or a
  /// plain number: the number and its unit (empty for a plain number). Numbers no notification
  /// could mean (not finite, or a billion or more either way) don't count.
  static func quantity(_ value: Any?) -> (number: Double, unit: String)? {
    let number: Double
    let unit: String
    switch value {
    case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID():
      (number, unit) = (value.doubleValue, "")
    case let string as String:
      let parts = string.split(separator: " ", maxSplits: 1)
      guard let first = parts.first, let value = Double(first) else { return nil }
      (number, unit) = (value, parts.count > 1 ? String(parts[1]) : "")
    default:
      return nil
    }
    guard number.isFinite, abs(number) < 1e9 else { return nil }
    return (number, unit)
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
  /// Low cardio fitness: the VO₂ max, and the threshold it was below if known, in mL/kg·min.
  case cardioFitness(vo2Max: Double, threshold: Double?)
  /// Low cardio fitness without its VO₂ max: the threshold it was below.
  case cardioFitnessThreshold(Double)
  /// Noise or headphone audio: the level in dB, and for how many seconds if known.
  case soundExposure(level: Double, duration: TimeInterval?)
  /// Noise or headphone audio without its level: for how many seconds.
  case soundDuration(TimeInterval)
  /// Walking steadiness, as Health names its value: "Low", "Still Very Low".
  case walkingSteadiness(String)
  /// Irregular rhythm, sleep apnea and hypertension: the period it was found in.
  case period(DateInterval)

  /// The line a notification's row shows: "Above 120 BPM", "92 dB for 4 min".
  public func line(calendar: Calendar) -> String {
    let locale = calendar.locale ?? .current
    func number(_ value: Double) -> String { Self.number(value, locale: locale) }
    func whole(_ value: Double) -> String { Self.whole(value, locale: locale) }
    switch self {
    case .heartRateAbove(let threshold):
      return "Above \(whole(threshold)) BPM"
    case .heartRateBelow(let threshold):
      return "Below \(whole(threshold)) BPM"
    case .cardioFitness(let vo2Max, let threshold?):
      return "\(number(vo2Max)) VO₂ max, below \(number(threshold))"
    case .cardioFitness(let vo2Max, nil):
      return "\(number(vo2Max)) VO₂ max"
    case .cardioFitnessThreshold(let threshold):
      return "Below \(number(threshold)) VO₂ max"
    case .soundExposure(let level, let duration?):
      return "\(whole(level)) dB for \(Self.duration(duration, locale: locale))"
    case .soundExposure(let level, nil):
      return "\(whole(level)) dB"
    case .soundDuration(let duration):
      return "For \(Self.duration(duration, locale: locale))"
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

  /// A VO₂ max: "27.4", "30".
  public static func number(_ value: Double, locale: Locale) -> String {
    value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
  }

  /// A heart rate or sound level, to the nearest whole number: "120".
  public static func whole(_ value: Double, locale: Locale) -> String {
    value.formatted(.number.precision(.fractionLength(0)).locale(locale))
  }

  /// "45 sec", "4 min", "1 hr 15 min". Seconds too many to count in whole numbers stay seconds.
  public static func duration(_ seconds: TimeInterval, locale: Locale) -> String {
    guard seconds.isFinite, abs(seconds) < 1e15 else {
      return "\(whole(seconds, locale: locale)) sec"
    }
    let total = Int(seconds.rounded())
    guard total >= 60 else { return "\(total) sec" }
    let (hours, minutes) = (total / 3600, total % 3600 / 60)
    if hours == 0 { return "\(minutes) min" }
    return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
  }
}
