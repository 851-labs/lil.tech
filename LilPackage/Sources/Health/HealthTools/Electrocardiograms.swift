import Foundation
import HealthCatalog
import HealthDatabase
public import SQLiteData

// The ECG tools (851-4159): `electrocardiograms` lists recordings from their rows, in the words of
// the app's ECG page (`ElectrocardiogramsView.swift`), with the symptoms their links name
// (851-4187), and `electrocardiogram_voltages` reads one recording's voltages from its blob, a
// page of seconds at a time, as the privacy policy says (851-4157). The remote server does the
// same (`Services/api/src/health/tools/Electrocardiograms.ts`), rule for rule.

extension HealthTools {
  /// The most ECGs `electrocardiograms` lists.
  public static let electrocardiogramsLimit = 100
  /// The seconds of a recording `electrocardiogram_voltages` gives a page by default, and at most.
  public static let voltagesDefaultSeconds = 10
  public static let voltagesMaxSeconds = 30
  /// The most values a page of voltages has: Apple Watch's whole recording, 30 seconds at 512 Hz.
  /// A page that would have more is downsampled, so it stays under the 256 KB ceiling.
  public static let voltagesValueLimit = 15_360

  // MARK: - electrocardiograms

  /// The recordings that start in the period, newest first, at most `electrocardiogramsLimit`,
  /// with how many there are.
  public func electrocardiograms(
    range: ToolRange, date: String? = nil, timeZone: String? = nil, _ db: Database
  ) throws -> HealthElectrocardiogramsResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    let period = try ToolPeriod(range, date: date, now: now, time: time)
    let (count, recordings) = try HealthDatabase.electrocardiograms(
      in: period.interval, limit: Self.electrocardiogramsLimit, db)
    let zones = RecordedZones()
    return HealthElectrocardiogramsResult(
      timeZone: time.name, range: range.rawValue, start: time.localTime(period.start),
      end: time.localTime(period.end), count: count,
      recordings: try recordings.map { recording in
        let metadata = SampleDetails.object(recording.metadata)
        let recorded = zones.times(metadata, start: recording.startDate, end: recording.endDate)
        return HealthElectrocardiogramItem(
          id: recording.id,
          start: time.localTime(Date(unixMilliseconds: recording.startDate)),
          end: time.localTime(Date(unixMilliseconds: recording.endDate)),
          recordedTimeZone: recorded.timeZone, recordedStart: recorded.start,
          recordedEnd: recorded.end,
          duration: Double(recording.endDate - recording.startDate) / 1000,
          classification: recording.decodedClassification.name,
          averageHeartRate: recording.averageHeartRate,
          samplingFrequency: recording.samplingFrequency, voltageCount: recording.voltageCount,
          symptoms: recording.symptomsName,
          loggedSymptoms: try HealthDatabase.symptoms(ofElectrocardiogram: recording.id, db)
            .samples?.map { symptom in
              HealthElectrocardiogramSymptom(
                type: symptom.type, name: HealthCatalog.type(id: symptom.type)?.name ?? symptom.type
              )
            },
          algorithmVersion: HealthMetadataValues.value(.appleECGAlgorithmVersion, in: metadata)?
            .double,
          source: recording.sourceName)
      })
  }

  // MARK: - electrocardiogram_voltages

  /// A page of a recording's voltages: `seconds` of it at its own rate, or downsampled to at most
  /// `voltagesValueLimit` values. The cursor is the index of the page's first measurement.
  public func electrocardiogramVoltages(
    id: String, timeZone: String? = nil, cursor: String? = nil, seconds: Int? = nil,
    _ db: Database
  ) throws -> HealthElectrocardiogramVoltagesResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    // Checked before the voltages, which may have to be downloaded.
    let seconds = seconds ?? Self.voltagesDefaultSeconds
    guard (1...Self.voltagesMaxSeconds).contains(seconds) else {
      throw HealthToolError("The seconds must be from 1 to \(Self.voltagesMaxSeconds).")
    }
    let invalidCursor = HealthToolError(
      "Invalid cursor: \(cursor ?? ""). Pass the previous page's nextCursor.")
    let start = try cursor.map { cursor in
      guard let index = Self.cursorIndex(cursor) else { throw invalidCursor }
      return index
    }
    guard let recording = try HealthElectrocardiogram.where({ $0.id.eq(id) }).fetchOne(db) else {
      throw HealthToolError("No ECG with ID \(id). electrocardiograms lists them, with their IDs.")
    }
    guard let sha256 = recording.voltages else {
      throw HealthToolError("The ECG \(id) has no voltage measurements (its voltageCount is 0).")
    }
    let values = HealthDatabase.electrocardiogramMicrovolts(try blob(sha256))
    let first = start ?? 0
    guard first <= values.count else { throw invalidCursor }
    let frequency = recording.measurementsPerSecond
    // Measurements a page covers, at least one, and never more than the recording has (a rate
    // that isn't plausible could make it any number).
    let perPage = Int(max(1, min(Double(values.count), (frequency * Double(seconds)).rounded())))
    let every = (perPage + Self.voltagesValueLimit - 1) / Self.voltagesValueLimit
    let end = min(first + perPage, values.count)
    return HealthElectrocardiogramVoltagesResult(
      timeZone: time.name, id: recording.id,
      start: time.localTime(Date(unixMilliseconds: recording.startDate)),
      samplingFrequency: frequency, voltageCount: values.count,
      offset: Double(first) / frequency, rate: frequency / Double(every),
      measurementsPerValue: every,
      values: stride(from: first, to: end, by: every).map { group in
        Self.average(values[group..<min(group + every, end)])
      },
      nextCursor: end < values.count ? String(end) : nil)
  }

  /// The average of the measurements that have a value, to 2 decimal places, or `nil` if none
  /// has one, as the remote server works it out.
  private static func average(_ measurements: ArraySlice<Float>) -> Double? {
    var (sum, count) = (0.0, 0)
    for measurement in measurements where measurement.isFinite {
      sum += Double(measurement)
      count += 1
    }
    return count == 0 ? nil : rounded(sum / Double(count), 100)
  }
}

// MARK: - Outputs

/// An ECG recording, in the words of the Mac's ECG page.
public struct HealthElectrocardiogramItem: Codable, Equatable, Sendable {
  public var id: String
  public var start: String
  public var end: String
  /// The zone it was recorded in (`HKTimeZone`), when it's a name the tools take, and its start
  /// and end on that zone's clock (851-4177); `nil` without one, and left out of the JSON.
  public var recordedTimeZone: String? = nil
  public var recordedStart: String? = nil
  public var recordedEnd: String? = nil
  /// Seconds.
  public var duration: Double
  /// E.g. `Sinus Rhythm`, as `ECGClassification` names it.
  public var classification: String
  /// Beats per minute.
  public var averageHeartRate: Double?
  /// Hz, as recorded.
  public var samplingFrequency: Double?
  public var voltageCount: Int
  /// `Symptoms Logged`, `No Symptoms` or `Not Logged`.
  public var symptoms: String
  /// Those logged with it that have arrived, in order of start (851-4187); nil when its link
  /// record hasn't synced (an iPhone from before 851-4153) or there were too many to upload.
  public var loggedSymptoms: [HealthElectrocardiogramSymptom]?
  /// `HKMetadataKeyAppleECGAlgorithmVersion`, left out of the JSON when it doesn't say.
  public var algorithmVersion: Double? = nil
  public var source: String

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encodeIfPresent(recordedTimeZone, forKey: .recordedTimeZone)
    try container.encodeIfPresent(recordedStart, forKey: .recordedStart)
    try container.encodeIfPresent(recordedEnd, forKey: .recordedEnd)
    try container.encode(duration, .duration)
    try container.encode(classification, .classification)
    try container.encode(averageHeartRate, .averageHeartRate)
    try container.encode(samplingFrequency, .samplingFrequency)
    try container.encode(voltageCount, .voltageCount)
    try container.encode(symptoms, .symptoms)
    try container.encode(loggedSymptoms, .loggedSymptoms)
    try container.encodeIfPresent(algorithmVersion, forKey: .algorithmVersion)
    try container.encode(source, .source)
  }
}

/// A symptom logged with an ECG: its type, and the name Health gives it.
public struct HealthElectrocardiogramSymptom: Codable, Equatable, Sendable {
  public var type: String
  public var name: String
}

public struct HealthElectrocardiogramsResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var count: Int
  public var recordings: [HealthElectrocardiogramItem]
}

public struct HealthElectrocardiogramVoltagesResult: HealthToolOutput {
  public var timeZone: String
  public var id: String
  /// When the recording starts.
  public var start: String
  /// The recording's measurements per second (`measurementsPerSecond`).
  public var samplingFrequency: Double
  public var voltageCount: Int
  /// Seconds from the recording's start to the page's first value.
  public var offset: Double
  /// The page's values per second.
  public var rate: Double
  public var measurementsPerValue: Int
  /// Microvolts, to 2 decimal places, `nil` where the recording has no value.
  public var values: [Double?]
  public var nextCursor: String?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(timeZone, .timeZone)
    try container.encode(id, .id)
    try container.encode(start, .start)
    try container.encode(samplingFrequency, .samplingFrequency)
    try container.encode(voltageCount, .voltageCount)
    try container.encode(offset, .offset)
    try container.encode(rate, .rate)
    try container.encode(measurementsPerValue, .measurementsPerValue)
    try container.encode(values, .values)
    try container.encode(nextCursor, .nextCursor)
  }
}
