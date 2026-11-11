import Testing

@testable import HealthCatalog

// What a sample's details call each metadata key (851-4169): HealthKit's keys in words, whether
// their value has the `HKMetadataKey` prefix or not.
@Suite struct HealthMetadataKeyLabelTests {
  @Test func constantsReadAsWords() {
    #expect(
      HealthMetadataKey.words("HKMetadataKeyHeartRateEventThreshold")
        == "Heart Rate Event Threshold")
    // Acronyms stay whole, a digit ends a word, and short words are in lower case after the first.
    #expect(HealthMetadataKey.words("HKMetadataKeySWOLFScore") == "SWOLF Score")
    #expect(HealthMetadataKey.words("HKMetadataKeyVO2MaxValue") == "VO2 Max Value")
    #expect(
      HealthMetadataKey.words("HKMetadataKeyDateOfEarliestDataUsedForEstimate")
        == "Date of Earliest Data Used for Estimate")
  }

  @Test func everyKeyHasALabelOfItsOwn() {
    let keys = HealthCatalog.healthKitMetadataKeys
    #expect(HealthCatalog.healthKitMetadataKeysByKey["HKTimeZone"]?.label == "Time Zone")
    #expect(
      HealthCatalog.healthKitMetadataKeysByKey["HKWasUserEntered"]?.label == "Entered by Hand")
    #expect(
      HealthCatalog.healthKitMetadataKeysByKey["HKHeartRateEventThreshold"]?.label
        == "Heart Rate Event Threshold")
    #expect(Set(keys.map(\.label)).count == keys.count, "Two keys share a label")
    for key in keys {
      #expect(!key.label.isEmpty && !key.label.contains("HK"), "\(key.constant): \(key.label)")
      #expect(!key.label.contains("  "), "\(key.constant): \(key.label)")
    }
  }
}
