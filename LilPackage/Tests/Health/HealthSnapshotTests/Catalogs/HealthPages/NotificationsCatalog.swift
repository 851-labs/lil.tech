#if os(macOS)
  import Foundation
  import HealthDatabase
  @testable import HealthPages
  import SwiftUI
  import Testing

  // A kind's notifications (`HealthNotificationsContent`) and a notification's detail
  // (`NotificationDetailContent`). Synthetic data only: made-up notifications, with metadata as
  // the iPhone uploads it (quantities as their descriptions). Dated before October 14, 2025, not
  // `previewNow`: the views show no date relative to now.

  extension MacSnapshotTests {
    @Test(arguments: notificationsCatalog.selectedStates)
    func notifications(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let notificationsCatalog = StateCatalog(
    "Notifications", width: 620, minHeight: 520,
    states: [
      CatalogState("High heart rate notifications") {
        list(.highHeartRate, .loaded(highHeartRate))
      },
      CatalogState("Walking steadiness notifications") {
        list(.walkingSteadiness, .loaded(walkingSteadiness))
      },
      CatalogState("Noise notifications") { list(.noise, .loaded(noise)) },
      CatalogState("Noise notifications, at the limit") {
        list(.noise, .loaded(noise), limit: noise.count)
      },
      CatalogState("Low cardio fitness, missing metadata") {
        list(.lowCardioFitness, .loaded(lowCardioFitness))
      },
      // Its lungs symbol draws a few pixels 2 apart on the minis (M6) and on a laptop (M1 Pro),
      // on the same macOS 27.0.1: past CI's tolerance (851-2985), within a laptop's. Its
      // references are the minis', as every one is (851-3070).
      CatalogState("Sleep apnea notifications") { list(.sleepApnea, .loaded(sleepApnea)) },
      CatalogState("No high heart rate notifications") { list(.highHeartRate, .loaded([])) },
      CatalogState("No walking steadiness notifications") {
        list(.walkingSteadiness, .loaded([]))
      },
      CatalogState("Notifications loading") { list(.highHeartRate, .loading) },
      CatalogState("Notifications failed") {
        list(.highHeartRate, .failed("The database couldn't be read."))
      },
      // A notification's detail.
      CatalogState("High heart rate notification", minHeight: 640) {
        detail(
          .highHeartRate, highHeartRate[0],
          heartRates: .loaded(heartRates(around: highHeartRate[0])))
      },
      CatalogState("Heart rate loading", minHeight: 640) {
        detail(.highHeartRate, highHeartRate[1])
      },
      CatalogState("No heart rate readings", minHeight: 640) {
        detail(.highHeartRate, highHeartRate[2], heartRates: .loaded([]))
      },
      CatalogState("Heart rate failed", minHeight: 640) {
        detail(
          .highHeartRate, highHeartRate[3], heartRates: .failed("The database couldn't be read."))
      },
      CatalogState("Noise notification", minHeight: 640) { detail(.noise, noise[0]) },
      CatalogState("Irregular rhythm notification", minHeight: 640) {
        detail(
          .irregularRhythm,
          notification(.irregularRhythm, daysAgo: 6, hour: 2, minutes: 5 * 60))
      },
      CatalogState("Notification, unknown metadata", minHeight: 640) {
        detail(.lowCardioFitness, lowCardioFitness[2])
      },
    ],
    // The heart rate chart keeps its height, loading or not, so the source below stays put
    // (851-3091).
    sameLayout: [
      [
        "High heart rate notification", "Heart rate loading", "No heart rate readings",
        "Heart rate failed",
      ]
    ])

  /// 2025-10-14 00:00 UTC.
  private let base = Date(timeIntervalSince1970: 1_760_400_000)

  private func notification(
    _ kind: HealthNotificationKind, daysAgo: Double, hour: Double = 14, minutes: Double = 10,
    value: Int = 0, metadata: String? = nil, device: String? = "Apple Watch"
  ) -> HealthNotification {
    let start = base.addingTimeInterval(-daysAgo * 86_400 + hour * 3600)
    let sample = HealthSample(
      id: "notification-\(kind)-\(daysAgo)", type: kind.rawValue,
      startDate: start.unixMilliseconds,
      endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, categoryValue: value,
      sourceName: device == "iPhone" ? "iPhone" : "Apple Watch",
      sourceBundleID: "com.apple.health.preview",
      device: device.map { #"{"name":"\#($0)","manufacturer":"Apple Inc."}"# },
      metadata: metadata)
    return HealthNotification(sample)
  }

  private let highHeartRate = [
    notification(
      .highHeartRate, daysAgo: 0, metadata: #"{"HKHeartRateEventThreshold":"120 count/min"}"#),
    notification(
      .highHeartRate, daysAgo: 9, hour: 22,
      metadata: #"{"HKHeartRateEventThreshold":"120 count/min"}"#),
    notification(
      .highHeartRate, daysAgo: 23, hour: 9,
      metadata: #"{"HKHeartRateEventThreshold":"130 count/min"}"#),
    notification(
      .highHeartRate, daysAgo: 61, hour: 16,
      metadata: #"{"HKHeartRateEventThreshold":"120 count/min"}"#),
  ]

  private let walkingSteadiness = [
    notification(.walkingSteadiness, daysAgo: 2, minutes: 0, value: 3, device: "iPhone"),
    notification(.walkingSteadiness, daysAgo: 40, minutes: 0, value: 4, device: "iPhone"),
    notification(.walkingSteadiness, daysAgo: 75, minutes: 0, value: 2, device: "iPhone"),
    notification(.walkingSteadiness, daysAgo: 130, minutes: 0, value: 1, device: "iPhone"),
  ]

  private let noise = [
    notification(
      .noise, daysAgo: 1, hour: 21, minutes: 4,
      metadata: #"{"HKAudioExposureLevel":"96.2 dBASPL","HKAudioExposureDuration":"240 s"}"#),
    notification(
      .noise, daysAgo: 5, hour: 13, minutes: 3,
      metadata: #"{"HKAudioExposureLevel":"91.8 dBASPL","HKAudioExposureDuration":"180 s"}"#),
    notification(
      .noise, daysAgo: 33, hour: 19, minutes: 1,
      metadata: #"{"HKAudioExposureLevel":"100 dBASPL"}"#),
  ]

  /// One with what it measured, one without any metadata, and one with only another app's key.
  private let lowCardioFitness = [
    notification(
      .lowCardioFitness, daysAgo: 3, minutes: 0,
      metadata:
        #"{"HKVO2MaxValue":"27.4 ml/kg*min","HKLowCardioFitnessEventThreshold":"30.1 ml/kg*min"}"#
    ),
    notification(.lowCardioFitness, daysAgo: 95, minutes: 0),
    notification(
      .lowCardioFitness, daysAgo: 190, minutes: 0, metadata: #"{"com.example.reason":"Estimated"}"#
    ),
  ]

  private let sleepApnea = [
    notification(.sleepApnea, daysAgo: 4, hour: 7, minutes: 30 * 24 * 60),
    notification(.sleepApnea, daysAgo: 210, hour: 7, minutes: 30 * 24 * 60),
  ]

  /// Heart rate every 30 seconds from 10 minutes before the notification to 10 minutes after,
  /// above 120 BPM during it.
  private func heartRates(around notification: HealthNotification) -> [HealthSample] {
    let window = NotificationDetailContent.heartRateWindow(notification.sample)
    let count = Int(window.duration / 30)
    return (0..<count).map { index in
      let start = window.start.addingTimeInterval(Double(index) * 30)
      let during = notification.sample.start...notification.sample.end ~= start
      let value = (during ? 126 : 104) + 6 * sin(Double(index) / 3) + Double(index % 3)
      return HealthSample(
        id: "heart-rate-\(index)", type: HealthDatabase.heartRateType,
        startDate: start.unixMilliseconds, endDate: start.unixMilliseconds, value: value,
        unit: "count/min", sourceName: "Apple Watch", sourceBundleID: "com.apple.health.preview")
    }
  }

  @MainActor
  private func list(
    _ kind: HealthNotificationKind, _ state: HealthNotificationsContent.State,
    limit: Int = RecentNotifications.limit
  ) -> some View {
    NavigationStack {
      HealthNotificationsContent(kind: kind, state: state, limit: limit)
    }
  }

  @MainActor
  private func detail(
    _ kind: HealthNotificationKind, _ notification: HealthNotification,
    heartRates: NotificationDetailContent.HeartRates = .loading
  ) -> some View {
    NavigationStack {
      NotificationDetailContent(kind: kind, notification: notification, heartRates: heartRates)
    }
  }
#endif
