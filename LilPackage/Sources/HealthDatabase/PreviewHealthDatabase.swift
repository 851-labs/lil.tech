public import Foundation
import HealthCatalog
public import SQLiteData

/// A database with two weeks of synthetic health data across every category, for previews
/// (AGENTS.md). Values are made up but plausible for each type's unit, and the same for the same
/// `now`.
public func makePreviewHealthDatabase(
  now: Date = .now, calendar: Calendar = .current
) -> any DatabaseWriter {
  do {
    let database = try HealthDatabase.make()
    try database.write { db in try PreviewData(now: now, calendar: calendar).insert(db) }
    return database
  } catch {
    fatalError("Couldn't make the preview health database: \(error)")
  }
}

/// The iPhone the preview data comes from.
let previewDevice = "dev_000000000000000000000000ph"

private struct PreviewData {
  let now: Date
  let calendar: Calendar
  let days = 14

  /// Midnight of each day, oldest first, ending today.
  var dayStarts: [Date] {
    let today = calendar.startOfDay(for: now)
    return (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
  }

  func insert(_ db: Database) throws {
    try HealthStatisticsDevice.insert {
      HealthStatisticsDevice(
        id: previewDevice, device: previewDevice, pairedWithWatch: true,
        reportedAt: now.unixMilliseconds)
    }
    .execute(db)

    for type in HealthCatalog.all {
      var random = SplitMix64(seed: type.id)
      switch type.kind {
      case .quantity where type.aggregation?.isCumulative == true:
        try insertStatistics(of: type, &random, db)
      case .quantity:
        try insertSamples(of: type, &random, db)
      case .category:
        try insertCategorySamples(of: type, &random, db)
      default:
        break
      }
    }
    try insertBloodPressure(db)
    try insertCharacteristics(db)
    try insertActivitySummaries(db)
  }

  /// 30-minute sums from 7:00 to 23:00, plus a few raw samples a day.
  private func insertStatistics(
    of type: HealthDataType, _ random: inout SplitMix64, _ db: Database
  ) throws {
    let unit = type.unit ?? "count"
    let (low, high) = Self.range(for: type, perBucket: true)
    var statistics: [HealthStatistic] = []
    var samples: [HealthSample] = []
    for day in dayStarts {
      for halfHour in 14..<46 {
        // On UTC half-hours, like the server's buckets, even in :45 time zones.
        let local = day.addingTimeInterval(Double(halfHour) * 1800).timeIntervalSince1970
        let start = Date(timeIntervalSince1970: (local / 1800).rounded(.down) * 1800)
        guard start < now else { break }
        let sum = random.next(in: low...high)
        statistics.append(
          HealthStatistic(
            id: "\(previewDevice)/\(type.id)@\(start.unixMilliseconds)", device: previewDevice,
            type: type.id, bucketStart: start.unixMilliseconds, sum: sum, unit: unit))
        if halfHour.isMultiple(of: 12) {
          samples.append(
            sample(type, start: start, minutes: 10, value: sum / 3, unit: unit, &random))
        }
      }
    }
    try HealthStatistic.insert { statistics }.execute(db)
    if !samples.isEmpty { try HealthSample.insert { samples }.execute(db) }
  }

  /// Every 30 minutes for heart rate, otherwise twice a day.
  private func insertSamples(
    of type: HealthDataType, _ random: inout SplitMix64, _ db: Database
  ) throws {
    let unit = type.unit ?? "count"
    let (low, high) = Self.range(for: type, perBucket: false)
    let hours: [Double] =
      type.id == "HKQuantityTypeIdentifierHeartRate"
      ? stride(from: 0, to: 24, by: 0.5).map(\.self) : [8, 20]
    var samples: [HealthSample] = []
    for day in dayStarts {
      for hour in hours {
        let start = day.addingTimeInterval(hour * 3600)
        guard start < now else { break }
        samples.append(
          sample(
            type, start: start, minutes: 1, value: random.next(in: low...high), unit: unit,
            &random))
      }
    }
    if !samples.isEmpty { try HealthSample.insert { samples }.execute(db) }
  }

  /// Sleep stages every night, stand hours every day, and other events every few days.
  private func insertCategorySamples(
    of type: HealthDataType, _ random: inout SplitMix64, _ db: Database
  ) throws {
    var samples: [HealthSample] = []
    for (index, day) in dayStarts.enumerated() {
      switch type.id {
      case "HKCategoryTypeIdentifierSleepAnalysis":
        // In bed from 23:00, cycling through core (3), deep (4), REM (5) and awake (2).
        let bedtime = day.addingTimeInterval(-3600)
        var start = bedtime
        for stage in [3, 4, 3, 5, 3, 4, 5, 2, 3, 5] {
          let minutes = random.next(in: 25...60)
          guard start < now else { break }
          samples.append(
            sample(type, start: start, minutes: minutes, categoryValue: stage, &random))
          start = start.addingTimeInterval(minutes * 60)
        }
        // In bed (0) from a little before falling asleep to a little after waking.
        let inBed = bedtime.addingTimeInterval(-15 * 60)
        // Not past now, for tonight's night.
        let outOfBed = min(start.addingTimeInterval(10 * 60), now)
        if outOfBed > inBed {
          samples.append(
            sample(
              type, start: inBed, minutes: outOfBed.timeIntervalSince(inBed) / 60, categoryValue: 0,
              &random))
        }
      case "HKCategoryTypeIdentifierAppleStandHour":
        for hour in 8..<21 {
          let start = day.addingTimeInterval(Double(hour) * 3600)
          guard start < now else { break }
          let stood = random.next(in: 0...1) < 0.8 ? 0 : 1
          samples.append(sample(type, start: start, minutes: 60, categoryValue: stood, &random))
        }
      default:
        guard index.isMultiple(of: 3) else { continue }
        let start = day.addingTimeInterval(14 * 3600)
        guard start < now else { continue }
        samples.append(sample(type, start: start, minutes: 30, categoryValue: 0, &random))
      }
    }
    if !samples.isEmpty { try HealthSample.insert { samples }.execute(db) }
  }

  /// A blood pressure reading every other morning.
  private func insertBloodPressure(_ db: Database) throws {
    var random = SplitMix64(seed: "HKCorrelationTypeIdentifierBloodPressure")
    for (index, day) in dayStarts.enumerated() where index.isMultiple(of: 2) {
      let start = day.addingTimeInterval(7.5 * 3600)
      guard start < now else { continue }
      let correlation = random.uuid()
      try HealthCorrelation.insert {
        HealthCorrelation(
          id: correlation, type: "HKCorrelationTypeIdentifierBloodPressure",
          startDate: start.unixMilliseconds, endDate: start.unixMilliseconds,
          sourceName: "Blood Pressure Monitor", sourceBundleID: "com.example.bloodpressure")
      }
      .execute(db)
      for (id, range) in [("Systolic", 112.0...128.0), ("Diastolic", 70.0...84.0)] {
        guard let type = HealthCatalog.type(id: "HKQuantityTypeIdentifierBloodPressure\(id)")
        else { continue }
        var reading = sample(
          type, start: start, minutes: 0, value: random.next(in: range).rounded(), unit: "mmHg",
          &random)
        reading.correlationID = correlation
        reading.sourceName = "Blood Pressure Monitor"
        try HealthSample.insert { reading }.execute(db)
      }
    }
  }

  private func insertCharacteristics(_ db: Database) throws {
    try HealthCharacteristic.insert {
      HealthCharacteristic(
        id: "HKCharacteristicTypeIdentifierDateOfBirth", value: #"{"day":2,"month":4,"year":1990}"#)
      HealthCharacteristic(id: "HKCharacteristicTypeIdentifierBiologicalSex", value: #""female""#)
      HealthCharacteristic(id: "HKCharacteristicTypeIdentifierBloodType", value: #""aPositive""#)
    }
    .execute(db)
  }

  private func insertActivitySummaries(_ db: Database) throws {
    var random = SplitMix64(seed: "HKActivitySummary")
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let summaries = dayStarts.map { day in
      HealthActivitySummary(
        id: formatter.string(from: day),
        activeEnergyBurned: random.next(in: 280...720).rounded(), activeEnergyBurnedGoal: 500,
        appleMoveTime: nil, appleMoveTimeGoal: nil,
        appleExerciseTime: random.next(in: 10...60).rounded(), appleExerciseTimeGoal: 30,
        appleStandHours: random.next(in: 8...13).rounded(), appleStandHoursGoal: 12,
        activityMoveMode: "activeEnergy", paused: false)
    }
    try HealthActivitySummary.insert { summaries }.execute(db)
  }

  private func sample(
    _ type: HealthDataType, start: Date, minutes: Double, value: Double? = nil,
    unit: String? = nil, categoryValue: Int? = nil, _ random: inout SplitMix64
  ) -> HealthSample {
    let fromWatch = type.category == .heart || type.id.hasSuffix("SleepAnalysis")
    return HealthSample(
      id: random.uuid(), type: type.id, startDate: start.unixMilliseconds,
      endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, value: value, unit: unit,
      categoryValue: categoryValue,
      sourceName: fromWatch ? "Apple Watch" : "iPhone",
      sourceBundleID: fromWatch ? "com.apple.health.watch" : "com.apple.health.iphone",
      sourceRevision: fromWatch ? Self.watchRevision : Self.phoneRevision,
      device: fromWatch ? Self.watch : Self.phone,
      metadata: type.id == "HKQuantityTypeIdentifierHeartRate"
        ? #"{"HKMetadataKeyHeartRateMotionContext":1}"# : nil)
  }

  // Made-up devices, in the shape the iPhone uploads (`HealthEncoder.provenance`).
  static let watch =
    #"{"hardwareVersion":"Watch7,1","manufacturer":"Apple Inc.","model":"Watch","name":"Apple Watch","softwareVersion":"26.0"}"#
  static let phone =
    #"{"hardwareVersion":"iPhone17,1","manufacturer":"Apple Inc.","model":"iPhone","name":"iPhone","softwareVersion":"26.0"}"#
  static let watchRevision =
    #"{"operatingSystemVersion":"26.0.0","productType":"Watch7,1","version":"26.0"}"#
  static let phoneRevision =
    #"{"operatingSystemVersion":"26.0.0","productType":"iPhone17,1","version":"26.0"}"#

  /// Plausible values for a type: per sample, or per 30-minute bucket for cumulative types.
  static func range(for type: HealthDataType, perBucket: Bool) -> (Double, Double) {
    switch type.unit {
    case "count": perBucket ? (0, 400) : (1, 10)
    case "m": perBucket ? (0, 600) : (300, 600)
    case "kcal": perBucket ? (5, 40) : (100, 300)
    case "min": (0, 10)
    case "mg": (0, 60)
    case "mcg": (0, 20)
    case "g": (0, 30)
    case "IU": (0, 100)
    case "L", "mL": perBucket ? (0, 0.4) : (3, 5)
    case "%": (0.94, 0.99)
    case "count/min": (56, 110)
    case "m/s": (0.9, 1.5)
    case "degC": (36.3, 37.1)
    case "W": (100, 250)
    case "dBASPL": (55, 80)
    case "ms": (30, 80)
    case "kg": (70, 72)
    case "cm": (170, 171)
    case "mmHg": (70, 128)
    case "mg/dL": (80, 120)
    default: (1, 10)
    }
  }
}

/// A small seeded generator, so preview data is the same every time.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: String) {
    // FNV-1a, since `hashValue` changes between launches.
    state = seed.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
  }

  mutating func next() -> UInt64 {
    state &+= 0x9e37_79b9_7f4a_7c15
    var z = state
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
  }

  mutating func next(in range: ClosedRange<Double>) -> Double {
    Double.random(in: range, using: &self)
  }

  /// A lowercase UUID, like a HealthKit sample's.
  mutating func uuid() -> String {
    let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &self) }
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      )
    ).uuidString.lowercased()
  }
}
