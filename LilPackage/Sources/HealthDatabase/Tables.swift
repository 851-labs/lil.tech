public import Foundation
public import SQLiteData

// Local copies of the server's health entities (`Services/api/src/health/HealthEntities.ts`).
// Times are Unix milliseconds, as on the server. JSON fields are stored as JSON text.

/// A quantity or category sample, keyed by HealthKit's UUID.
@Table
public struct HealthSample: Equatable, Identifiable, Sendable {
  public let id: String
  /// The HealthKit type identifier, e.g. `HKQuantityTypeIdentifierStepCount`.
  public var type: String
  public var startDate: Int
  public var endDate: Int
  /// A quantity sample's value, in `unit`.
  public var value: Double?
  public var unit: String?
  /// A category sample's value (`HKCategoryValue…`).
  public var categoryValue: Int?
  public var correlationID: String?
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?

  public init(
    id: String, type: String, startDate: Int, endDate: Int, value: Double? = nil,
    unit: String? = nil, categoryValue: Int? = nil, correlationID: String? = nil,
    sourceName: String, sourceBundleID: String, sourceRevision: String? = nil,
    device: String? = nil, metadata: String? = nil
  ) {
    self.id = id
    self.type = type
    self.startDate = startDate
    self.endDate = endDate
    self.value = value
    self.unit = unit
    self.categoryValue = categoryValue
    self.correlationID = correlationID
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
  }

  public var start: Date { Date(unixMilliseconds: startDate) }
  public var end: Date { Date(unixMilliseconds: endDate) }
}

/// A blood pressure or food correlation. Its samples point at it with `correlationID`.
@Table
public struct HealthCorrelation: Equatable, Identifiable, Sendable {
  public let id: String
  public var type: String
  public var startDate: Int
  public var endDate: Int
  public var sourceName: String
  public var sourceBundleID: String
  public var sourceRevision: String?
  public var device: String?
  public var metadata: String?

  public init(
    id: String, type: String, startDate: Int, endDate: Int, sourceName: String,
    sourceBundleID: String, sourceRevision: String? = nil, device: String? = nil,
    metadata: String? = nil
  ) {
    self.id = id
    self.type = type
    self.startDate = startDate
    self.endDate = endDate
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.sourceRevision = sourceRevision
    self.device = device
    self.metadata = metadata
  }
}

/// A characteristic (date of birth, blood type…), keyed by its type identifier.
@Table
public struct HealthCharacteristic: Equatable, Identifiable, Sendable {
  public let id: String
  /// JSON, e.g. `{"day":2,"month":4,"year":1990}` or an enum case's name.
  public var value: String

  public init(id: String, value: String) {
    self.id = id
    self.value = value
  }
}

/// The Activity rings for one day, keyed by the day (`YYYY-MM-DD` in the iPhone's calendar).
@Table
public struct HealthActivitySummary: Equatable, Identifiable, Sendable {
  public let id: String
  public var activeEnergyBurned: Double?
  public var activeEnergyBurnedGoal: Double?
  public var appleMoveTime: Double?
  public var appleMoveTimeGoal: Double?
  public var appleExerciseTime: Double?
  public var appleExerciseTimeGoal: Double?
  public var appleStandHours: Double?
  public var appleStandHoursGoal: Double?
  public var activityMoveMode: String?
  public var paused: Bool?

  public init(
    id: String, activeEnergyBurned: Double? = nil, activeEnergyBurnedGoal: Double? = nil,
    appleMoveTime: Double? = nil, appleMoveTimeGoal: Double? = nil,
    appleExerciseTime: Double? = nil, appleExerciseTimeGoal: Double? = nil,
    appleStandHours: Double? = nil, appleStandHoursGoal: Double? = nil,
    activityMoveMode: String? = nil, paused: Bool? = nil
  ) {
    self.id = id
    self.activeEnergyBurned = activeEnergyBurned
    self.activeEnergyBurnedGoal = activeEnergyBurnedGoal
    self.appleMoveTime = appleMoveTime
    self.appleMoveTimeGoal = appleMoveTimeGoal
    self.appleExerciseTime = appleExerciseTime
    self.appleExerciseTimeGoal = appleExerciseTimeGoal
    self.appleStandHours = appleStandHours
    self.appleStandHoursGoal = appleStandHoursGoal
    self.activityMoveMode = activityMoveMode
    self.paused = paused
  }
}

/// A cumulative type's sum over one 30-minute bucket, as one iPhone's HealthKit computed it.
@Table
public struct HealthStatistic: Equatable, Identifiable, Sendable {
  /// `<device>/<type>@<bucketStart>`.
  public let id: String
  public var device: String
  public var type: String
  public var bucketStart: Int
  public var sum: Double
  public var unit: String

  public init(id: String, device: String, type: String, bucketStart: Int, sum: Double, unit: String)
  {
    self.id = id
    self.device = device
    self.type = type
    self.bucketStart = bucketStart
    self.sum = sum
    self.unit = unit
  }
}

/// One iPhone's statistics status, keyed by its device ID.
@Table
public struct HealthStatisticsDevice: Equatable, Identifiable, Sendable {
  public let id: String
  public var device: String
  public var pairedWithWatch: Bool
  /// When the server last applied its report.
  public var reportedAt: Int

  public init(id: String, device: String, pairedWithWatch: Bool, reportedAt: Int) {
    self.id = id
    self.device = device
    self.pairedWithWatch = pairedWithWatch
    self.reportedAt = reportedAt
  }
}

extension Date {
  public init(unixMilliseconds: Int) {
    self.init(timeIntervalSince1970: Double(unixMilliseconds) / 1000)
  }

  public var unixMilliseconds: Int { Int((timeIntervalSince1970 * 1000).rounded()) }
}
