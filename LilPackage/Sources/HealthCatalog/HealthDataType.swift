/// One kind of Apple Health data, described the way lil health syncs and displays it.
///
/// The catalog is plain data: identifiers are HealthKit's raw strings, so it builds for every
/// platform and OS version we support, including types newer than the deployment target.
public struct HealthDataType: Hashable, Identifiable, Sendable {
  /// HealthKit's identifier, e.g. `HKQuantityTypeIdentifierStepCount`.
  public let id: String
  public let kind: Kind
  /// The name Health shows, e.g. "Steps".
  public let name: String
  /// The Browse category whose screen shows the type. `nil` for characteristics, which Health
  /// shows in Health Details instead of Browse.
  public let category: HealthCategory?
  /// Other Browse categories that also list the type (e.g. Heart Rate under Vitals).
  public let alsoListedIn: Set<HealthCategory>
  /// The unit lil health stores quantities in, as an `HKUnit` unit string. Only for quantity types.
  public let unit: String?
  /// How HealthKit combines samples of a quantity type. Only for quantity types.
  public let aggregation: Aggregation?
  /// The iOS version that introduced the type.
  public let introduced: IOSVersion
  public let readAuthorization: ReadAuthorization

  public enum Kind: String, Hashable, Sendable {
    case quantity
    case category
    case correlation
    case characteristic
    case workout
    case workoutRoute
    case activitySummary
    case heartbeatSeries
    case electrocardiogram
    case audiogram
    case stateOfMind
    case scoredAssessment
    case medication
    case medicationDoseEvent
    case visionPrescription
    case document
  }

  /// How an app gets permission to read the type.
  public enum ReadAuthorization: String, Hashable, Sendable {
    /// Requested with `HKHealthStore.requestAuthorization(toShare:read:)`.
    case standard
    /// Requested with `requestPerObjectReadAuthorization(for:predicate:)`, where the user picks
    /// individual objects. Passing it to `requestAuthorization` throws.
    case perObject
    /// Can't be requested itself. Correlations are read through their component types.
    case throughComponents
    /// HealthKit doesn't let third-party apps read it.
    case unavailable
  }

  /// Mirrors `HKQuantityAggregationStyle`.
  public enum Aggregation: String, Hashable, Sendable {
    /// Samples add up (steps, energy). Daily values are sums.
    case cumulative
    /// Samples average arithmetically (weight, blood glucose).
    case discreteArithmetic
    /// Samples average weighted by the time between them (heart rate).
    case discreteTemporallyWeighted
    /// Sound levels, averaged as an equivalent continuous level.
    case discreteEquivalentContinuousLevel

    public var isCumulative: Bool { self == .cumulative }
  }
}

public struct IOSVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int

  public init(_ major: Int, _ minor: Int = 0) {
    self.major = major
    self.minor = minor
  }

  public static func ios(_ major: Int, _ minor: Int = 0) -> Self {
    Self(major, minor)
  }

  public var description: String { "\(major).\(minor)" }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
  }
}
