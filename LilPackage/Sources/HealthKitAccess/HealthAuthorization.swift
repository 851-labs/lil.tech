public import Dependencies
import Foundation
public import HealthCatalog
public import HealthKit
public import ObjectiveC

extension DependencyValues {
  /// Asking for read access to Apple Health.
  public var healthAuthorization: HealthAuthorization {
    get { self[HealthAuthorization.self] }
    set { self[HealthAuthorization.self] = newValue }
  }
}

/// Types HealthKit asks about one object at a time, in their own sheet.
public enum PerObjectHealthType: String, CaseIterable, Sendable {
  /// The medication list. Dose events are readable through the same choice.
  case medications
  case visionPrescriptions

  /// The catalog type whose sheet this is.
  public var catalogType: HealthDataType? {
    let kind: HealthDataType.Kind =
      switch self {
      case .medications: .medication
      case .visionPrescriptions: .visionPrescription
      }
    return HealthCatalog.all.first { $0.kind == kind && $0.readAuthorization == .perObject }
  }
}

/// Read access to Apple Health. HealthKit never says which types were denied: a denied type just
/// returns nothing.
public struct HealthAuthorization: Sendable {
  /// Whether this device has Health at all (iPhone yes, iPad and Mac no).
  public var isAvailable: @Sendable () -> Bool
  /// Whether the system sheet still has types to ask about, e.g. on first launch, or after an
  /// update that reads new types.
  public var needsRequest: @Sendable () async throws -> Bool
  /// Shows the system sheet for every standard read type, characteristics included.
  public var requestRead: @Sendable () async throws -> Void
  /// Shows the sheet where the person picks which medications or prescriptions to share. Having
  /// none, or closing the sheet, isn't an error.
  public var requestPerObject: @Sendable (PerObjectHealthType) async throws -> Void

  public init(
    isAvailable: @escaping @Sendable () -> Bool,
    needsRequest: @escaping @Sendable () async throws -> Bool,
    requestRead: @escaping @Sendable () async throws -> Void,
    requestPerObject: @escaping @Sendable (PerObjectHealthType) async throws -> Void
  ) {
    self.isAvailable = isAvailable
    self.needsRequest = needsRequest
    self.requestRead = requestRead
    self.requestPerObject = requestPerObject
  }

  /// The types the system sheet asks about on this OS version.
  public static func readTypes(availableOn version: IOSVersion) -> Set<HKObjectType> {
    Set(HealthCatalog.standardReadTypes(availableOn: version).compactMap(\.objectType))
  }

  /// The iOS version the app runs on, to know which types exist.
  public static var currentVersion: IOSVersion {
    #if os(iOS)
      let version = ProcessInfo.processInfo.operatingSystemVersion
      return .ios(version.majorVersion, version.minorVersion)
    #else
      return .ios(26)
    #endif
  }
}

extension HealthAuthorization: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    let readTypes = readTypes(availableOn: currentVersion)
    return Self(
      isAvailable: { HKHealthStore.isHealthDataAvailable() },
      needsRequest: {
        try await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
          == .shouldRequest
      },
      requestRead: { try await store.requestAuthorization(toShare: [], read: readTypes) },
      requestPerObject: { type in
        guard let objectType = type.catalogType?.objectType else { return }
        do {
          try await store.requestPerObjectReadAuthorization(for: objectType, predicate: nil)
        } catch let error as HKError where [.errorNoData, .errorUserCanceled].contains(error.code) {
          // Nothing to choose from, or the sheet was closed: not a failure.
        }
      }
    )
  }

  public static let previewValue = Self(
    isAvailable: { true },
    needsRequest: { true },
    requestRead: {},
    requestPerObject: { _ in }
  )

  public static var testValue: Self {
    Self(
      isAvailable: {
        reportIssue("Unimplemented: @Dependency(\\.healthAuthorization).isAvailable")
        return true
      },
      needsRequest: {
        reportIssue("Unimplemented: @Dependency(\\.healthAuthorization).needsRequest")
        return false
      },
      requestRead: {
        reportIssue("Unimplemented: @Dependency(\\.healthAuthorization).requestRead")
      },
      requestPerObject: { _ in
        reportIssue("Unimplemented: @Dependency(\\.healthAuthorization).requestPerObject")
      }
    )
  }
}
