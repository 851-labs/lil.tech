import Foundation
import HealthDatabase
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md). Synthetic data only: made-up notifications, with metadata
// as the iPhone uploads it (quantities as their descriptions).

/// 2025-10-14 00:00 UTC.
private let base = Date(timeIntervalSince1970: 1_760_400_000)

private func notification(
  _ kind: HealthNotificationKind, daysAgo: Double, hour: Double = 14, minutes: Double = 10,
  value: Int = 0, metadata: String? = nil, device: String? = "Apple Watch"
) -> HealthSample {
  let start = base.addingTimeInterval(-daysAgo * 86_400 + hour * 3600)
  return HealthSample(
    id: "notification-\(kind)-\(daysAgo)", type: kind.rawValue,
    startDate: start.unixMilliseconds,
    endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, categoryValue: value,
    sourceName: device == "iPhone" ? "iPhone" : "Apple Watch",
    sourceBundleID: "com.apple.health.preview",
    device: device.map { #"{"name":"\#($0)","manufacturer":"Apple Inc."}"# },
    metadata: metadata)
}

private let highHeartRate = [
  notification(
    .highHeartRate, daysAgo: 0, metadata: #"{"HKHeartRateEventThreshold":"120 count/min"}"#),
  notification(
    .highHeartRate, daysAgo: 9, hour: 22,
    metadata: #"{"HKHeartRateEventThreshold":"120 count/min"}"#
  ),
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
    .noise, daysAgo: 33, hour: 19, minutes: 1, metadata: #"{"HKAudioExposureLevel":"100 dBASPL"}"#
  ),
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
    .lowCardioFitness, daysAgo: 190, minutes: 0, metadata: #"{"com.example.reason":"Estimated"}"#),
]

private let sleepApnea = [
  notification(.sleepApnea, daysAgo: 4, hour: 7, minutes: 30 * 24 * 60),
  notification(.sleepApnea, daysAgo: 210, hour: 7, minutes: 30 * 24 * 60),
]

@MainActor
private func list(_ kind: HealthNotificationKind, _ state: HealthNotificationsContent.State)
  -> some View
{
  NavigationStack {
    HealthNotificationsContent(kind: kind, state: state)
  }
  .previewFrame(width: 620, height: 520)
}

#Preview("High heart rate notifications") {
  list(.highHeartRate, .loaded(highHeartRate))
}

#Preview("Walking steadiness notifications") {
  list(.walkingSteadiness, .loaded(walkingSteadiness))
}

#Preview("Noise notifications") {
  list(.noise, .loaded(noise))
}

#Preview("Low cardio fitness, missing metadata") {
  list(.lowCardioFitness, .loaded(lowCardioFitness))
}

#Preview("Sleep apnea notifications") {
  list(.sleepApnea, .loaded(sleepApnea))
}

#Preview("No high heart rate notifications") {
  list(.highHeartRate, .loaded([]))
}

#Preview("No walking steadiness notifications") {
  list(.walkingSteadiness, .loaded([]))
}

#Preview("Notifications loading") {
  list(.highHeartRate, .loading)
}

#Preview("Notifications failed") {
  list(.highHeartRate, .failed("The database couldn't be read."))
}

/// Heart rate climbing past 120 BPM over the notification's 10 minutes, every 30 seconds.
private func previewHeartRates(during notification: HealthSample) -> [HealthSample] {
  (0..<20).map { index in
    let start = notification.start.addingTimeInterval(Double(index) * 30)
    let value = 124 + 10 * sin(Double(index) / 3) + Double(index % 3)
    return HealthSample(
      id: "heart-rate-\(index)", type: HealthDatabase.heartRateType,
      startDate: start.unixMilliseconds, endDate: start.unixMilliseconds, value: value,
      unit: "count/min", sourceName: "Apple Watch", sourceBundleID: "com.apple.health.preview")
  }
}

@MainActor
private func detail(
  _ kind: HealthNotificationKind, _ notification: HealthSample,
  heartRates: [HealthSample]? = nil
) -> some View {
  NavigationStack {
    NotificationDetailContent(kind: kind, notification: notification, heartRates: heartRates)
  }
  .previewFrame(width: 620, height: 640)
}

#Preview("High heart rate notification") {
  detail(.highHeartRate, highHeartRate[0], heartRates: previewHeartRates(during: highHeartRate[0]))
}

#Preview("Heart rate loading") {
  detail(.highHeartRate, highHeartRate[1])
}

#Preview("No heart rate readings") {
  detail(.highHeartRate, highHeartRate[2], heartRates: [])
}

#Preview("Noise notification") {
  detail(.noise, noise[0])
}

#Preview("Irregular rhythm notification") {
  detail(.irregularRhythm, notification(.irregularRhythm, daysAgo: 6, hour: 2, minutes: 5 * 60))
}

#Preview("Notification, unknown metadata") {
  detail(.lowCardioFitness, lowCardioFitness[2])
}
