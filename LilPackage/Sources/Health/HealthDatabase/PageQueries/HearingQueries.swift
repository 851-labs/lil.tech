public import Foundation
public import SQLiteData

extension HealthDatabase {
  /// Sound levels above this, in dB, are loud: over time they can affect hearing, so Health draws
  /// the line on the environmental and headphone audio charts.
  public static let loudSoundLevel = 80.0

  /// The sound level types that get the loud line.
  public static let soundLevelTypes: Set<String> = [
    "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
    "HKQuantityTypeIdentifierHeadphoneAudioExposure",
  ]

  /// The sound a week may hold before it's over the limit: 40 hours at `loudSoundLevel`, the
  /// WHO's safe listening level for adults, which Health's 7-day exposure and headphone
  /// notifications use (851-3100). Every 3 dB louder halves the time (equal energy).
  public static let weeklySoundAllowance: TimeInterval = 40 * 3600

  /// How much of `weeklySoundAllowance` a sound level type's samples in `range` add up to
  /// (851-3100): each sample's time in the range, weighted by its energy against
  /// `loudSoundLevel`'s, so an hour at 80 dB is 1/40 of the limit and an hour at 90 dB 10/40.
  /// Time without samples counts as quiet, as nothing measured it. `nil` without samples in the
  /// range.
  public static func soundExposure(
    of type: String, in range: Range<Date>, _ db: Database
  ) throws -> SoundExposure? {
    let lower = range.lowerBound.unixMilliseconds
    let upper = range.upperBound.unixMilliseconds
    // Samples that start up to a day early can reach into the range; Health's are minutes long.
    let earliest = range.lowerBound.addingTimeInterval(-86_400).unixMilliseconds
    let rows =
      try HealthSample
      .where {
        $0.type.eq(type) && $0.startDate >= earliest && $0.startDate < upper
          && $0.endDate > lower
      }
      .select { ($0.startDate, $0.endDate, $0.value) }
      .fetchAll(db)
    var seconds = 0.0
    var hasSamples = false
    for (start, end, value) in rows {
      guard let value else { continue }
      hasSamples = true
      let overlap = Double(min(end, upper) - max(start, lower)) / 1000
      seconds += max(overlap, 0) * pow(10, (value - loudSoundLevel) / 10)
    }
    return hasSamples ? SoundExposure(dose: seconds / weeklySoundAllowance) : nil
  }

  /// Audiograms, newest first, at most `limit`.
  public static func audiograms(limit: Int, _ db: Database) throws -> [HealthAudiogram] {
    try HealthAudiogram
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
  }

  /// The audiograms that start in `range`, newest first (then by ID), at most `limit`, and how
  /// many there are in all: the `audiograms` tool's (851-4161).
  public static func audiograms(in range: Range<Date>, limit: Int, _ db: Database) throws
    -> (count: Int, audiograms: [HealthAudiogram])
  {
    let (lower, upper) = (range.lowerBound.unixMilliseconds, range.upperBound.unixMilliseconds)
    let inRange = HealthAudiogram.where { $0.startDate >= lower && $0.startDate < upper }
    let audiograms = try inRange.order { ($0.startDate.desc(), $0.id.desc()) }.limit(limit)
      .fetchAll(db)
    // Counted only when they don't all fit.
    return (audiograms.count < limit ? audiograms.count : try inRange.fetchCount(db), audiograms)
  }
}

/// A week's sound exposure against Health's limit (`HealthDatabase.soundExposure`).
public struct SoundExposure: Equatable, Sendable {
  /// The share of the weekly limit used: 1 is the limit, 0.5 half of it.
  public var dose: Double

  public init(dose: Double) {
    self.dose = dose
  }

  /// Whether it reached the limit, which Health calls loud.
  public var isOverLimit: Bool { dose >= 1 }
}

/// An ear, as HealthKit numbers them (`HKAudiogramSensitivityTest.Side`).
public enum Ear: Int, CaseIterable, Sendable {
  case left = 0
  case right = 1

  public var name: String { self == .left ? "Left Ear" : "Right Ear" }
}

/// One tested frequency: each ear's sensitivity there, in dBHL (lower hears better).
public struct AudiogramPoint: Equatable, Sendable {
  public var frequency: Double
  public var left: Double?
  public var right: Double?
  /// Ears whose result is a bound, not a threshold: no response up to the device's loudest, so
  /// the threshold is at or past it (`clampingUpper` missing, `clampingLower` set).
  public var clamped: Set<Ear>

  public init(frequency: Double, left: Double?, right: Double?, clamped: Set<Ear> = []) {
    self.frequency = frequency
    self.left = left
    self.right = right
    self.clamped = clamped
  }

  public func sensitivity(_ ear: Ear) -> Double? { ear == .left ? left : right }
}

/// How much hearing loss a hearing level means, as Health groups it.
public enum HearingLevel: Equatable, Sendable, CaseIterable {
  case normal, mild, moderate, severe, profound

  public init(decibels: Double) {
    self =
      switch decibels {
      case ...25: .normal
      case ...40: .mild
      case ...60: .moderate
      case ...80: .severe
      default: .profound
      }
  }

  public var name: String {
    switch self {
    case .normal: "Little to No Hearing Loss"
    case .mild: "Mild Hearing Loss"
    case .moderate: "Moderate Hearing Loss"
    case .severe: "Severe Hearing Loss"
    case .profound: "Profound Hearing Loss"
    }
  }

  /// Its band on the chart, in dBHL.
  public var range: ClosedRange<Double> {
    switch self {
    case .normal: -10...25
    case .mild: 25...40
    case .moderate: 40...60
    case .severe: 60...80
    case .profound: 80...120
    }
  }
}

/// One test of an ear at a frequency (`HKAudiogramSensitivityTest`), as synced: sensitivity and
/// clamping bounds in dBHL.
public struct AudiogramTest: Equatable, Sendable {
  /// `HKAudiogramSensitivityTestSide`: 0 the left ear, 1 the right (`Ear`).
  public var side: Int
  /// `HKAudiogramConductionType`, 0 air (the only one so far); `nil` counts as air.
  public var type: Int?
  public var masked: Bool?
  public var sensitivity: Double
  public var clampingLower: Double?
  public var clampingUpper: Double?

  public init(
    side: Int, type: Int? = nil, masked: Bool? = nil, sensitivity: Double,
    clampingLower: Double? = nil, clampingUpper: Double? = nil
  ) {
    self.side = side
    self.type = type
    self.masked = masked
    self.sensitivity = sensitivity
    self.clampingLower = clampingLower
    self.clampingUpper = clampingUpper
  }

  /// Air conduction, as a test without a type is.
  public var isAirConduction: Bool { (type ?? 0) == 0 }
}

/// A tested frequency with every test there, as synced.
public struct AudiogramFrequency: Equatable, Sendable {
  public var frequency: Double
  public var tests: [AudiogramTest]

  public init(frequency: Double, tests: [AudiogramTest]) {
    self.frequency = frequency
    self.tests = tests
  }

  /// An ear's tests: the one that counts first, as hearing tests report it (air conduction,
  /// unmasked before masked, else the first), then the others as recorded. Empty if the ear
  /// wasn't tested here.
  public func tests(for ear: Ear) -> [AudiogramTest] {
    var ears = tests.filter { $0.side == ear.rawValue }
    guard
      let index = ears.firstIndex(where: { $0.isAirConduction && $0.masked != true })
        ?? ears.firstIndex(where: \.isAirConduction) ?? ears.indices.first
    else { return [] }
    let counted = ears.remove(at: index)
    return [counted] + ears
  }

  /// Each ear's sensitivity here, from the test that counts.
  public var point: AudiogramPoint {
    AudiogramPoint(frequency: frequency, left: tests(for: .left), right: tests(for: .right))
  }
}

extension AudiogramPoint {
  /// A frequency's point from each ear's tests, the one that counts first
  /// (`AudiogramFrequency.tests(for:)`).
  public init(frequency: Double, left: [AudiogramTest], right: [AudiogramTest]) {
    var clamped: Set<Ear> = []
    for (ear, test) in [(Ear.left, left.first), (.right, right.first)]
    where test?.clampingLower != nil && test?.clampingUpper == nil {
      clamped.insert(ear)
    }
    self.init(
      frequency: frequency, left: left.first?.sensitivity, right: right.first?.sensitivity,
      clamped: clamped)
  }
}

extension HealthAudiogram {
  /// Its frequencies, as recorded, with every test. Points and tests that can't be read are left
  /// out, each on its own, as the `audiograms` tool on the server reads them
  /// (`audiogramFrequencies`).
  public var decodedFrequencies: [AudiogramFrequency] {
    struct Lossy<Value: Decodable>: Decodable {
      let value: Value?
      init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }
    struct Point: Decodable {
      struct Test: Decodable {
        let side: Int
        let type: Int?
        let masked: Bool?
        let sensitivity: Double
        let clampingLower: Double?
        let clampingUpper: Double?
      }
      let frequency: Double
      let tests: [Lossy<Test>]
    }
    guard
      let points = try? JSONDecoder().decode([Lossy<Point>].self, from: Data(self.points.utf8))
    else { return [] }
    return points.compactMap(\.value).map { point in
      AudiogramFrequency(
        frequency: point.frequency,
        tests: point.tests.compactMap(\.value).map { test in
          AudiogramTest(
            side: test.side, type: test.type, masked: test.masked, sensitivity: test.sensitivity,
            clampingLower: test.clampingLower, clampingUpper: test.clampingUpper)
        })
    }
  }

  /// Its points, by frequency. For an ear tested more than one way at a frequency, an
  /// air-conduction test counts, unmasked first, as hearing tests report it. Points and tests
  /// that can't be read are left out, each on its own.
  public var decodedPoints: [AudiogramPoint] {
    decodedFrequencies.map(\.point)
  }
}

extension [AudiogramPoint] {
  /// An ear's hearing level, in whole dBHL as shown and classified: its average at 500, 1000,
  /// 2000 and 4000 Hz (the speech range), or over every frequency tested if it has none of
  /// those. `nil` if that ear wasn't tested.
  public func averageHearingLevel(_ ear: Ear) -> Double? {
    let speech: Set<Double> = [500, 1_000, 2_000, 4_000]
    let inSpeech = compactMap { speech.contains($0.frequency) ? $0.sensitivity(ear) : nil }
    let values = inSpeech.isEmpty ? compactMap { $0.sensitivity(ear) } : inSpeech
    guard !values.isEmpty else { return nil }
    return (values.reduce(0, +) / Double(values.count)).rounded()
  }
}
