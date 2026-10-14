import Foundation
import HealthCatalog
import HealthKit
import Testing

struct HealthCatalogTests {
  @Test
  func identifiersAreUnique() {
    let ids = HealthCatalog.all.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test
  func everyCategoryHasTypes() {
    for category in HealthCategory.allCases {
      #expect(!HealthCatalog.types(in: category).isEmpty, "\(category) has no types")
    }
  }

  @Test
  func onlyQuantitiesHaveUnitsAndAggregation() {
    for type in HealthCatalog.all {
      let isQuantity = type.kind == .quantity
      #expect((type.unit != nil) == isQuantity, "\(type.id)")
      #expect((type.aggregation != nil) == isQuantity, "\(type.id)")
    }
  }

  /// Every identifier the SDK declares is in the catalog with the SDK's iOS availability, and
  /// every catalog identifier exists in the SDK.
  @Test
  func matchesSDKIdentifiers() throws {
    let sdk = try SDKIdentifiers.load()
    let catalogIDs = Set(
      HealthCatalog.all.filter { SDKIdentifiers.prefixes.contains(where: $0.id.hasPrefix) }.map(
        \.id)
    )

    let missing = Set(sdk.keys).subtracting(catalogIDs)
    #expect(missing.isEmpty, "Missing from the catalog: \(missing.sorted())")

    let unknown = catalogIDs.subtracting(sdk.keys)
    #expect(unknown.isEmpty, "Not in the SDK: \(unknown.sorted())")

    for type in HealthCatalog.all {
      guard let introduced = sdk[type.id] else { continue }
      #expect(type.introduced == introduced, "\(type.id): SDK says iOS \(introduced)")
    }
  }

  @Test
  func quantityUnitsAndAggregationMatchHealthKit() {
    for type in HealthCatalog.all where type.kind == .quantity {
      let quantityType = HKQuantityType(HKQuantityTypeIdentifier(rawValue: type.id))
      if let unit = type.unit {
        #expect(quantityType.is(compatibleWith: HKUnit(from: unit)), "\(type.id): \(unit)")
      }
      #expect(type.aggregation == Aggregation(quantityType.aggregationStyle), "\(type.id)")
    }
  }

  @Test
  func specialTypeIdentifiersMatchHealthKit() {
    let expected: [HealthDataType.Kind: Set<String>] = [
      .workout: [HKObjectType.workoutType().identifier],
      .workoutRoute: [HKSeriesType.workoutRoute().identifier],
      .activitySummary: [HKObjectType.activitySummaryType().identifier],
      .heartbeatSeries: [HKSeriesType.heartbeat().identifier],
      .electrocardiogram: [HKObjectType.electrocardiogramType().identifier],
      .audiogram: [HKObjectType.audiogramSampleType().identifier],
      .stateOfMind: [HKObjectType.stateOfMindType().identifier],
      .medication: [HKObjectType.userAnnotatedMedicationType().identifier],
      .medicationDoseEvent: [HKObjectType.medicationDoseEventType().identifier],
      .visionPrescription: [HKObjectType.visionPrescriptionType().identifier],
    ]
    for (kind, identifiers) in expected {
      let catalog = Set(HealthCatalog.all.filter { $0.kind == kind }.map(\.id))
      #expect(catalog == identifiers, "\(kind)")
    }
  }

  @Test
  func availabilityFiltersNewerTypes() {
    let onIOS26 = Set(HealthCatalog.types(availableOn: IOSVersion(26)).map(\.id))
    #expect(onIOS26.contains("HKQuantityTypeIdentifierStepCount"))
    #expect(onIOS26.contains("HKMedicationDoseEventTypeIdentifierMedicationDoseEvent"))
    #expect(!onIOS26.contains("HKCategoryTypeIdentifierHypertensionEvent"))
    #expect(!onIOS26.contains("HKQuantityTypeIdentifierHeartRateVariabilityRMSSD"))
  }
}

private func Aggregation(_ style: HKQuantityAggregationStyle) -> HealthDataType.Aggregation? {
  switch style {
  case .cumulative: .cumulative
  case .discreteArithmetic: .discreteArithmetic
  case .discreteTemporallyWeighted: .discreteTemporallyWeighted
  case .discreteEquivalentContinuousLevel: .discreteEquivalentContinuousLevel
  @unknown default: nil
  }
}

/// Type identifiers declared in the macOS SDK's `HKTypeIdentifiers.h`, with their iOS
/// availability. Deprecated identifiers and clinical types (out of scope) are left out.
private enum SDKIdentifiers {
  static let prefixes = [
    "HKQuantityTypeIdentifier",
    "HKCategoryTypeIdentifier",
    "HKCorrelationTypeIdentifier",
    "HKCharacteristicTypeIdentifier",
    "HKDocumentTypeIdentifier",
    "HKScoredAssessmentTypeIdentifier",
  ]

  static func load() throws -> [String: IOSVersion] {
    let header = try String(
      contentsOf: sdkPath().appending(
        path: "System/Library/Frameworks/HealthKit.framework/Headers/HKTypeIdentifiers.h"
      ),
      encoding: .utf8
    )
    let declaration =
      /HK_EXTERN (HK\w+TypeIdentifier) const (\w+) (API_AVAILABLE|API_DEPRECATED\w*)\(.*?ios\((\d+)\.(\d+)/
    var identifiers: [String: IOSVersion] = [:]
    for line in header.split(separator: "\n") {
      guard let match = line.firstMatch(of: declaration) else { continue }
      let (_, typedef, name, availability, major, minor) = match.output
      guard
        prefixes.contains(String(typedef)),
        availability == "API_AVAILABLE",
        typedef != "HKClinicalTypeIdentifier"
      else { continue }
      identifiers[String(name)] = IOSVersion(Int(major)!, Int(minor)!)
    }
    return identifiers
  }

  private static func sdkPath() throws -> URL {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = ["--sdk", "macosx", "--show-sdk-path"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return URL(filePath: output.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
