import Foundation
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

  /// Audiograms, newest first, at most `limit`.
  public static func audiograms(limit: Int, _ db: Database) throws -> [HealthAudiogram] {
    try HealthAudiogram
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
  }
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

  public init(frequency: Double, left: Double?, right: Double?) {
    self.frequency = frequency
    self.left = left
    self.right = right
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

extension HealthAudiogram {
  /// Its points, by frequency. For an ear tested more than one way at a frequency, the unmasked
  /// air-conduction test counts, as hearing tests report it. Unreadable points are left out.
  public var decodedPoints: [AudiogramPoint] {
    struct Point: Decodable {
      struct Test: Decodable {
        let side: Int
        let type: Int?
        let masked: Bool?
        let sensitivity: Double
      }
      let frequency: Double
      let tests: [Test]
    }
    guard let points = try? JSONDecoder().decode([Point].self, from: Data(self.points.utf8))
    else { return [] }
    return points.map { point in
      func sensitivity(_ ear: Ear) -> Double? {
        let tests = point.tests.filter { $0.side == ear.rawValue }
        let preferred =
          tests.first { ($0.type ?? 0) == 0 && $0.masked != true } ?? tests.first
        return preferred?.sensitivity
      }
      return AudiogramPoint(
        frequency: point.frequency, left: sensitivity(.left), right: sensitivity(.right))
    }
  }
}

extension [AudiogramPoint] {
  /// An ear's hearing level: its average at 500, 1000, 2000 and 4000 Hz (the speech range),
  /// or over every frequency tested if it has none of those. `nil` if that ear wasn't tested.
  public func averageHearingLevel(_ ear: Ear) -> Double? {
    let speech: Set<Double> = [500, 1_000, 2_000, 4_000]
    let inSpeech = compactMap { speech.contains($0.frequency) ? $0.sensitivity(ear) : nil }
    let values = inSpeech.isEmpty ? compactMap { $0.sensitivity(ear) } : inSpeech
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }
}
