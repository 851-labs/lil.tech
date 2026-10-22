import Foundation
import Testing

@testable import HealthCatalog

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
  func onlyCharacteristicsHaveNoCategory() {
    for type in HealthCatalog.all {
      #expect((type.category == nil) == (type.kind == .characteristic), "\(type.id)")
    }
  }

  @Test
  func vitalsListsVitalSignsFromOtherCategories() {
    let vitals = Set(HealthCatalog.types(in: .vitals).map(\.id))
    #expect(vitals.contains("HKQuantityTypeIdentifierHeartRate"))
    #expect(vitals.contains("HKCorrelationTypeIdentifierBloodPressure"))
    #expect(vitals.contains("HKQuantityTypeIdentifierBodyTemperature"))
    let heartRate = HealthCatalog.type(id: "HKQuantityTypeIdentifierHeartRate")
    #expect(heartRate?.category == .heart)
  }

  @Test
  func onlyQuantitiesHaveUnitsAndAggregation() {
    for type in HealthCatalog.all {
      let isQuantity = type.kind == .quantity
      #expect((type.unit != nil) == isQuantity, "\(type.id)")
      #expect((type.aggregation != nil) == isQuantity, "\(type.id)")
    }
  }

  @Test
  func readAuthorization() {
    for type in HealthCatalog.all where type.kind == .correlation {
      #expect(type.readAuthorization == .throughComponents, "\(type.id)")
    }
    let standard = Set(HealthCatalog.standardReadTypes(availableOn: .ios(26)).map(\.id))
    #expect(standard.contains("HKQuantityTypeIdentifierStepCount"))
    #expect(!standard.contains("HKCorrelationTypeIdentifierBloodPressure"))
    #expect(!standard.contains("HKVisionPrescriptionTypeIdentifier"))
    #expect(!standard.contains("HKDataTypeUserAnnotatedMedicationConcept"))
    #expect(!standard.contains("HKQuantityTypeIdentifierNikeFuel"))
  }

  /// The server's copy (851-2857) is generated from this catalog, so the two can't drift.
  @Test
  func serverCatalogMatches() throws {
    let path = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "../../../../Services/api/health-catalog.json")
      .standardized
    let committed = try String(contentsOf: path, encoding: .utf8)
    #expect(
      committed == (try HealthCatalog.json()),
      "Services/api/health-catalog.json is out of date. Run scripts/format to regenerate it."
    )
  }

  @Test
  func workoutActivityNames() {
    #expect(HealthCatalog.workoutActivityName(37) == "Running")
    #expect(HealthCatalog.workoutActivityName(49) == "Track and Field")
    #expect(HealthCatalog.workoutActivityName(3000) == "Other")
    #expect(HealthCatalog.workoutActivityName(9_999) == "Workout")
  }

  @Test
  func availabilityFiltersNewerTypes() {
    let onIOS26 = Set(HealthCatalog.types(availableOn: .ios(26)).map(\.id))
    #expect(onIOS26.contains("HKQuantityTypeIdentifierStepCount"))
    #expect(onIOS26.contains("HKMedicationDoseEventTypeIdentifierMedicationDoseEvent"))
    #expect(!onIOS26.contains("HKCategoryTypeIdentifierHypertensionEvent"))
    #expect(!onIOS26.contains("HKQuantityTypeIdentifierHeartRateVariabilityRMSSD"))
  }
}

#if os(macOS)
  import HealthKit
  import HealthKitAccess

  /// Checks the catalog against the SDK's headers and HealthKit itself. The headers are read
  /// from the macOS SDK with `xcrun`, so these only run on macOS.
  struct HealthCatalogSDKTests {
    /// Every identifier the SDK declares is in the catalog with the SDK's iOS availability, and
    /// every catalog identifier exists in the SDK.
    @Test
    func matchesSDKIdentifiers() throws {
      let sdk = try SDKHeaders.load()
      let catalogIDs = Set(
        HealthCatalog.all.filter { SDKHeaders.typedefs.contains(where: $0.id.hasPrefix) }
          .map { SDKHeaders.constantNames[$0.id] ?? $0.id }
      )

      let missing = Set(sdk.identifiers.keys).subtracting(catalogIDs)
      #expect(missing.isEmpty, "Missing from the catalog: \(missing.sorted())")

      let unknown = catalogIDs.subtracting(sdk.identifiers.keys)
      #expect(unknown.isEmpty, "Not in the SDK: \(unknown.sorted())")

      for type in HealthCatalog.all {
        guard let introduced = sdk.identifiers[SDKHeaders.constantNames[type.id] ?? type.id]
        else { continue }
        #expect(type.introduced == introduced, "\(type.id): SDK says iOS \(introduced)")
      }
    }

    /// Catalog IDs are HealthKit's runtime values, which aren't always the constants' names.
    /// Types newer than this Mac's OS are skipped, since HealthKit doesn't know them yet.
    @Test
    func identifiersAreHealthKitsValues() {
      let os = ProcessInfo.processInfo.operatingSystemVersion
      let host = IOSVersion(os.majorVersion, os.minorVersion)
      for type in HealthCatalog.all where type.introduced <= host {
        let identifier: String?
        switch type.kind {
        case .correlation:
          identifier =
            HKObjectType.correlationType(forIdentifier: .init(rawValue: type.id))?
            .identifier
        case .quantity, .category, .characteristic, .document, .scoredAssessment:
          identifier = type.objectType?.identifier
        default:
          continue
        }
        #expect(identifier == type.id, "\(type.id) isn't a HealthKit identifier")
      }
      #expect(
        HKCategoryTypeIdentifier.environmentalAudioExposureEvent.rawValue
          == "HKCategoryTypeIdentifierAudioExposureEvent")
    }

    @Test
    func specialTypeAvailabilityMatchesSDK() throws {
      let sdk = try SDKHeaders.load()
      for type in HealthCatalog.all {
        guard let introduced = sdk.specialTypes[type.kind] else { continue }
        #expect(type.introduced == introduced, "\(type.id): SDK says iOS \(introduced)")
      }
      #expect(Set(sdk.specialTypes.keys).count == SDKHeaders.specialTypeDeclarations.count)
    }

    @Test
    func quantityUnitsAndAggregationMatchHealthKit() {
      for type in HealthCatalog.all where type.kind == .quantity {
        let quantityType = HKQuantityType(HKQuantityTypeIdentifier(rawValue: type.id))
        if let unit = type.unit {
          #expect(quantityType.is(compatibleWith: HKUnit(from: unit)), "\(type.id): \(unit)")
        }
        #expect(
          type.aggregation == HealthDataType.Aggregation(quantityType.aggregationStyle),
          "\(type.id)"
        )
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

    /// Every `HKWorkoutActivityType` the SDK declares has a name, and the catalog names nothing
    /// else, so only values a later iOS adds read "Workout". Names follow the cases', apart from
    /// where Health's differ, which catches a name filed under the wrong raw value.
    @Test
    func namesEveryWorkoutActivityType() throws {
      let sdk = try SDKHeaders.load()
      #expect(sdk.workoutActivityTypes.count > 80)
      let unknown = Set(HealthCatalog.workoutActivityNames.keys)
        .subtracting(sdk.workoutActivityTypes.keys)
      #expect(unknown.isEmpty, "Not in the SDK: \(unknown.sorted())")

      let healthsNames = [
        "StairClimbing": "Stair Stepper",
        "SkatingSports": "Skating",
        "SurfingSports": "Surfing",
        "SwimBikeRun": "Multisport",
      ]
      for (rawValue, caseName) in sdk.workoutActivityTypes.sorted(by: { $0.key < $1.key }) {
        guard let name = HealthCatalog.workoutActivityNames[rawValue] else {
          Issue.record("No name for HKWorkoutActivityType\(caseName) (\(rawValue))")
          continue
        }
        // "Track and Field" is `TrackAndField`.
        let expected = healthsNames[caseName] ?? caseName
        #expect(
          name.filter { $0 != " " }.lowercased() == expected.filter { $0 != " " }.lowercased(),
          "\(rawValue) is HKWorkoutActivityType\(caseName), not \(name)")
      }
      #expect(Int(HKWorkoutActivityType.underwaterDiving.rawValue) == 84)
      #expect(Int(HKWorkoutActivityType.other.rawValue) == 3000)
    }
  }

  extension HealthDataType.Aggregation {
    fileprivate init?(_ style: HKQuantityAggregationStyle) {
      switch style {
      case .cumulative: self = .cumulative
      case .discreteArithmetic: self = .discreteArithmetic
      case .discreteTemporallyWeighted: self = .discreteTemporallyWeighted
      case .discreteEquivalentContinuousLevel: self = .discreteEquivalentContinuousLevel
      @unknown default: return nil
      }
    }
  }

  /// Availability parsed from the macOS SDK's HealthKit headers.
  private struct SDKHeaders {
    /// Type identifiers declared in `HKTypeIdentifiers.h`, without deprecated ones. Clinical
    /// types are out of scope, so their typedef isn't listed.
    var identifiers: [String: IOSVersion] = [:]
    /// When each special type was introduced, from its identifier constant or type accessor.
    var specialTypes: [HealthDataType.Kind: IOSVersion] = [:]
    /// `HKWorkoutActivityType`'s cases by raw value, named without the prefix (`Running`),
    /// leaving out those the SDK marks unavailable on iOS and watchOS (Rest and Group).
    var workoutActivityTypes: [Int: String] = [:]

    /// Header constants whose runtime value isn't their name, by value.
    static let constantNames = [
      "HKCategoryTypeIdentifierAudioExposureEvent":
        "HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent"
    ]

    static let typedefs = [
      "HKQuantityTypeIdentifier",
      "HKCategoryTypeIdentifier",
      "HKCorrelationTypeIdentifier",
      "HKCharacteristicTypeIdentifier",
      "HKDocumentTypeIdentifier",
      "HKScoredAssessmentTypeIdentifier",
    ]

    /// The identifier constant (`HKTypeIdentifiers.h`) or type accessor (`HKObjectType.h`)
    /// that declares each special type's availability. `workoutType` has no annotation and
    /// dates from iOS 8, so the workout constant is used instead.
    static let specialTypeDeclarations: [String: HealthDataType.Kind] = [
      "HKWorkoutTypeIdentifier": .workout,
      "HKWorkoutRouteTypeIdentifier": .workoutRoute,
      "HKDataTypeIdentifierHeartbeatSeries": .heartbeatSeries,
      "HKVisionPrescriptionTypeIdentifier": .visionPrescription,
      "HKDataTypeIdentifierStateOfMind": .stateOfMind,
      "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent": .medicationDoseEvent,
      "HKDataTypeIdentifierUserAnnotatedMedicationConcept": .medication,
      "activitySummaryType": .activitySummary,
      "audiogramSampleType": .audiogram,
      "electrocardiogramType": .electrocardiogram,
    ]

    static func load() throws -> Self {
      let headers = try sdkPath().appending(
        path: "System/Library/Frameworks/HealthKit.framework/Headers")
      let typeIdentifiers = try String(
        contentsOf: headers.appending(path: "HKTypeIdentifiers.h"), encoding: .utf8)
      let objectType = try String(
        contentsOf: headers.appending(path: "HKObjectType.h"), encoding: .utf8)
      let workoutActivityType = try String(
        contentsOf: headers.appending(path: "HKWorkoutActivityType.h"), encoding: .utf8)

      var sdk = Self()
      let identifier =
        /HK_EXTERN (HK\w+TypeIdentifier) const (\w+) API_AVAILABLE\(.*?ios\((\d+)\.(\d+)/
      let constant = /HK_EXTERN NSString \* const (\w+) API_AVAILABLE\(.*?ios\((\d+)\.(\d+)/
      let accessor = /^\+ \(\w+ \*\)(\w+) API_AVAILABLE\(.*?ios\((\d+)\.(\d+)/

      for line in typeIdentifiers.split(separator: "\n") {
        if let match = line.firstMatch(of: identifier), typedefs.contains(String(match.output.1)) {
          sdk.identifiers[String(match.output.2)] = IOSVersion(
            Int(match.output.3)!, Int(match.output.4)!)
        } else if let match = line.firstMatch(of: constant),
          let kind = specialTypeDeclarations[String(match.output.1)]
        {
          sdk.specialTypes[kind] = IOSVersion(Int(match.output.2)!, Int(match.output.3)!)
        }
      }
      for line in objectType.split(separator: "\n") {
        if let match = line.firstMatch(of: accessor),
          let kind = specialTypeDeclarations[String(match.output.1)]
        {
          sdk.specialTypes[kind] = IOSVersion(Int(match.output.2)!, Int(match.output.3)!)
        }
      }
      // The enum's body, whose cases may wrap over lines. Availability attributes have no `=`.
      let activityEnum =
        /typedef NS_ENUM\(NSUInteger, HKWorkoutActivityType\) \{([^}]*)\}/
      let activityCase = /HKWorkoutActivityType(\w+)([^=]*)=\s*(\d+)/
      let unavailable = /API_UNAVAILABLE\(([^)]*)\)/
      if let body = workoutActivityType.firstMatch(of: activityEnum)?.output.1 {
        for match in body.matches(of: activityCase) {
          // Only cases no app on the iPhone or Watch can save are left out (Rest, Group).
          let platforms = match.output.2.firstMatch(of: unavailable).map {
            Set($0.output.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
          }
          if let platforms, platforms.isSuperset(of: ["ios", "watchos"]) { continue }
          sdk.workoutActivityTypes[Int(match.output.3)!] = String(match.output.1)
        }
      }
      return sdk
    }

    private static func sdkPath() throws -> URL {
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/xcrun")
      process.arguments = ["--sdk", "macosx", "--show-sdk-path"]
      let pipe = Pipe()
      process.standardOutput = pipe
      try process.run()
      let output = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw XcrunError(status: process.terminationStatus)
      }
      return URL(
        filePath: String(decoding: output, as: UTF8.self).trimmingCharacters(
          in: .whitespacesAndNewlines))
    }

    struct XcrunError: Error, CustomStringConvertible {
      let status: Int32
      var description: String { "xcrun --show-sdk-path failed with status \(status)" }
    }
  }
#endif
