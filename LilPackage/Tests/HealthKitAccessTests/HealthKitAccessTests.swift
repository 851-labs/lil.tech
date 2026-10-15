import HealthCatalog
import HealthKit
import HealthKitAccess
import Testing

struct HealthKitAccessTests {
  @Test
  func everyStandardReadTypeHasAHealthKitType() {
    for type in HealthCatalog.standardReadTypes(availableOn: .ios(26)) {
      #expect(type.objectType != nil, "\(type.id)")
    }
  }

  @Test
  func theSheetAsksForCharacteristicsButNotCorrelationsOrPerObjectTypes() {
    let identifiers = Set(HealthAuthorization.readTypes(availableOn: .ios(26)).map(\.identifier))
    #expect(identifiers.contains("HKQuantityTypeIdentifierStepCount"))
    #expect(identifiers.contains("HKCharacteristicTypeIdentifierDateOfBirth"))
    #expect(identifiers.contains(HKObjectType.workoutType().identifier))
    #expect(!identifiers.contains("HKCorrelationTypeIdentifierBloodPressure"))
    #expect(!identifiers.contains(HKObjectType.userAnnotatedMedicationType().identifier))
    #expect(!identifiers.contains(HKObjectType.visionPrescriptionType().identifier))
    #expect(!identifiers.contains("HKQuantityTypeIdentifierNikeFuel"))
  }

  @Test
  func newerTypesOnlyOnNewerVersions() {
    let older = HealthAuthorization.readTypes(availableOn: .ios(17)).map(\.identifier)
    #expect(!older.contains(HKObjectType.stateOfMindType().identifier))
    let newer = HealthAuthorization.readTypes(availableOn: .ios(18)).map(\.identifier)
    #expect(newer.contains(HKObjectType.stateOfMindType().identifier))
  }
}
