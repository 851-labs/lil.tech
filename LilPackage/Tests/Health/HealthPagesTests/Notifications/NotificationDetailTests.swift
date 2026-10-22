import Foundation
import HealthDatabase
import Testing

@testable import HealthPages

// Synthetic data only (AGENTS.md).
struct NotificationDetailTests {
  private func sample(minutes: Double) -> HealthSample {
    let start = Date(timeIntervalSince1970: 1_760_400_000)
    return HealthSample(
      id: "notification", type: HealthNotificationKind.highHeartRate.rawValue,
      startDate: start.unixMilliseconds,
      endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, categoryValue: 0,
      sourceName: "Apple Watch", sourceBundleID: "com.example.watch")
  }

  @Test
  func heartRateIsChartedTenMinutesEitherSide() {
    let notification = sample(minutes: 10)
    let window = NotificationDetailContent.heartRateWindow(notification)
    #expect(window.start == notification.start.addingTimeInterval(-600))
    #expect(window.end == notification.end.addingTimeInterval(600))

    // An instant one still shows the readings around it.
    let instant = sample(minutes: 0)
    #expect(NotificationDetailContent.heartRateWindow(instant).duration == 1_200)
  }
}
