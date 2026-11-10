#if canImport(HealthKit)
  import HealthKit
  import Testing

  @testable import HealthDatabase

  /// The metadata keys notifications are read by are the SDK's strings, not names written by hand
  /// that the tests and catalog then repeat: noise and headphone notifications read keys HealthKit
  /// never writes until 851-4148, and every test passed.
  struct NotificationMetadataKeyTests {
    @Test
    func keysAreTheSDKs() {
      typealias Key = HealthDatabase.NotificationMetadataKey
      #expect(Key.heartRateThreshold == HKMetadataKeyHeartRateEventThreshold)
      #expect(Key.vo2Max == HKMetadataKeyVO2MaxValue)
      #expect(Key.cardioFitnessThreshold == HKMetadataKeyLowCardioFitnessEventThreshold)
      #expect(Key.audioLevel == HKMetadataKeyAudioExposureLevel)
      #expect(Key.audioDuration == HKMetadataKeyAudioExposureDuration)
    }
  }
#endif
