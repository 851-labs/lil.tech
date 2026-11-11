import Foundation
import HealthDatabase
public import SQLiteData

// The `audiograms` tool (851-4161): audiograms in a period, in the words of the app's Audiogram
// page (`AudiogramsView.swift`): each ear's hearing level and what it means, and every
// frequency's tests, read by `HealthAudiogram.decodedFrequencies`. The remote server does the
// same (`Services/api/src/health/tools/Audiograms.ts`), rule for rule.

extension HealthTools {
  /// The most audiograms `audiograms` lists.
  public static let audiogramsLimit = 30

  /// The audiograms that start in the period, newest first, at most `audiogramsLimit`, with how
  /// many there are.
  public func audiograms(
    range: ToolRange, date: String? = nil, timeZone: String? = nil, _ db: Database
  ) throws -> HealthAudiogramsResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    let period = try ToolPeriod(range, date: date, now: now, time: time)
    let (count, audiograms) = try HealthDatabase.audiograms(
      in: period.interval, limit: Self.audiogramsLimit, db)
    let zones = RecordedZones()
    return HealthAudiogramsResult(
      timeZone: time.name, range: range.rawValue, start: time.localTime(period.start),
      end: time.localTime(period.end), count: count,
      audiograms: audiograms.map { audiogram in
        // Each ear's tests, the one that counts first, worked out once.
        let frequencies = audiogram.decodedFrequencies.map {
          (hertz: $0.frequency, left: $0.tests(for: .left), right: $0.tests(for: .right))
        }
        let points = frequencies.map {
          AudiogramPoint(frequency: $0.hertz, left: $0.left, right: $0.right)
        }
        let recorded = zones.times(
          json: audiogram.metadata, start: audiogram.startDate, end: audiogram.endDate)
        return HealthAudiogramItem(
          id: audiogram.id,
          start: time.localTime(Date(unixMilliseconds: audiogram.startDate)),
          end: time.localTime(Date(unixMilliseconds: audiogram.endDate)),
          recordedTimeZone: recorded.timeZone, recordedStart: recorded.start,
          recordedEnd: recorded.end,
          leftEar: HealthAudiogramEar(points.averageHearingLevel(.left)),
          rightEar: HealthAudiogramEar(points.averageHearingLevel(.right)),
          points: frequencies.map { frequency in
            HealthAudiogramPoint(
              frequency: frequency.hertz + 0, left: frequency.left.map(HealthAudiogramTest.init),
              right: frequency.right.map(HealthAudiogramTest.init))
          },
          source: audiogram.sourceName)
      })
  }
}

// MARK: - Outputs

/// One test of an ear at a frequency, in dBHL.
public struct HealthAudiogramTest: Codable, Equatable, Sendable {
  public var sensitivity: Double
  /// `Air`, or `Unknown` for a conduction type a later iOS adds.
  public var conduction: String
  public var masked: Bool
  /// Whether it has a clamping range: the result is a bound, not a threshold.
  public var clamped: Bool
  /// The clamping range's bounds, left out of the JSON without them.
  public var clampingLower: Double? = nil
  public var clampingUpper: Double? = nil

  init(_ test: AudiogramTest) {
    // `+ 0`, so none is `-0`, as on the server.
    sensitivity = test.sensitivity + 0
    conduction = test.isAirConduction ? "Air" : "Unknown"
    masked = test.masked == true
    clamped = test.clampingLower != nil || test.clampingUpper != nil
    clampingLower = test.clampingLower.map { $0 + 0 }
    clampingUpper = test.clampingUpper.map { $0 + 0 }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sensitivity, .sensitivity)
    try container.encode(conduction, .conduction)
    try container.encode(masked, .masked)
    try container.encode(clamped, .clamped)
    try container.encodeIfPresent(clampingLower, forKey: .clampingLower)
    try container.encodeIfPresent(clampingUpper, forKey: .clampingUpper)
  }
}

/// A frequency tested, with each ear's tests, the one the page charts first.
public struct HealthAudiogramPoint: Codable, Equatable, Sendable {
  /// Hz.
  public var frequency: Double
  public var left: [HealthAudiogramTest]
  public var right: [HealthAudiogramTest]
}

/// An ear's hearing level and what it means, as the Audiogram page's headline has them.
public struct HealthAudiogramEar: Codable, Equatable, Sendable {
  /// Whole dBHL (`averageHearingLevel`), `nil` if the ear wasn't tested.
  public var hearingLevel: Double?
  /// `HearingLevel`'s name, e.g. `Mild Hearing Loss`.
  public var hearingLoss: String?

  init(_ level: Double?) {
    hearingLevel = level.map { $0 + 0 }
    hearingLoss = level.map { HearingLevel(decibels: $0).name }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(hearingLevel, .hearingLevel)
    try container.encode(hearingLoss, .hearingLoss)
  }
}

/// An audiogram, in the words of the Mac's Audiogram page.
public struct HealthAudiogramItem: Codable, Equatable, Sendable {
  public var id: String
  public var start: String
  public var end: String
  /// The zone it was recorded in (`HKTimeZone`), when it's a name the tools take, and its start
  /// and end on that zone's clock (851-4177); `nil` without one, and left out of the JSON.
  public var recordedTimeZone: String? = nil
  public var recordedStart: String? = nil
  public var recordedEnd: String? = nil
  public var leftEar: HealthAudiogramEar
  public var rightEar: HealthAudiogramEar
  public var points: [HealthAudiogramPoint]
  public var source: String

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encodeIfPresent(recordedTimeZone, forKey: .recordedTimeZone)
    try container.encodeIfPresent(recordedStart, forKey: .recordedStart)
    try container.encodeIfPresent(recordedEnd, forKey: .recordedEnd)
    try container.encode(leftEar, .leftEar)
    try container.encode(rightEar, .rightEar)
    try container.encode(points, .points)
    try container.encode(source, .source)
  }
}

public struct HealthAudiogramsResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var count: Int
  public var audiograms: [HealthAudiogramItem]
}
