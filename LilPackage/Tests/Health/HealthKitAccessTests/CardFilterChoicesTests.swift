import Testing

@testable import HealthKitAccess

/// The editor's filter choices from HealthKit (851-3213): each device model once, the most samples
/// first.
struct CardFilterChoicesTests {
  @Test
  func modelsAreOrderedByHowManySamplesTheyRecorded() {
    let models = ["iPhone", "Watch", "Watch", "Scale", "Watch", "iPhone"]
    #expect(HealthKitCardEngine.models(models) == ["Watch", "iPhone", "Scale"])
  }
}
