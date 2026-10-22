#if os(macOS)
  import AppKit
  import ComposableArchitecture
  import Foundation
  import HealthAgentAccess
  import HealthCatalog
  import HealthDatabase
  import LilAuth
  import LilSync
  @testable import HealthMacApp
  @testable import HealthPages
  import SnapshotTesting
  import SwiftUI
  import Testing

  // Preview states of lil health for Mac, light and dark (851-2931). Each builds the same view as
  // the `#Preview` it names, from fixed dates. Synthetic data only.

  // Serialized: a snapshot runs the main run loop, where another could start and change the
  // app's appearance.
  @MainActor
  @Suite(.serialized)
  struct MacSnapshotTests {
    /// The previews' synthetic database, which the chart's page reads (its preview prepares it
    /// too), prepared once per process, as a preview context does.
    static let database: Void = preparePreviewDatabase()

    init() {
      // Before any test builds its dates.
      prepareSnapshotEnvironment()
    }

    // MetricDetailViewPreviews.swift, "Environmental sound levels, week": a chart from fixed dates.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func soundLevelsChart(appearance: NSAppearance.Name) {
      _ = Self.database
      let calendar = Calendar.current
      let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_400_000))
      let days = (0..<7).map { calendar.date(byAdding: .day, value: $0 - 6, to: today)! }
      let ranges: [(Double, Double)] = [
        (42, 71), (45, 86), (40, 68), (38, 74), (44, 91), (41, 66), (39, 70),
      ]
      let points = zip(days, ranges).map { day, range in
        ChartPoint(start: day, value: (range.0 + range.1) / 2, minimum: range.0, maximum: range.1)
      }
      let chart = MetricChart(
        interval: DateInterval(
          start: days[0], end: calendar.date(byAdding: .day, value: 1, to: today)!),
        points: points, summary: .range(minimum: 38, maximum: 91))
      let view = NavigationStack {
        MetricDetailContent(
          type: HealthCatalog.type(id: "HKQuantityTypeIdentifierEnvironmentalAudioExposure")!,
          range: .constant(.week), offset: .constant(0), state: .loaded(chart))
      }
      .previewFrame(width: 760, height: 720)
      assertMacSnapshot(of: view, appearance: appearance, named: "sound-levels-week")
    }

    // HealthNotificationsViewPreviews.swift, "High heart rate notifications": a `List`.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func notificationsList(appearance: NSAppearance.Name) {
      let base = Date(timeIntervalSince1970: 1_760_400_000)
      func notification(daysAgo: Double, hour: Double = 14, threshold: Int) -> HealthNotification {
        let start = base.addingTimeInterval(-daysAgo * 86_400 + hour * 3600)
        return HealthNotification(
          HealthSample(
            id: "notification-\(HealthNotificationKind.highHeartRate)-\(daysAgo)",
            type: HealthNotificationKind.highHeartRate.rawValue,
            startDate: start.unixMilliseconds,
            endDate: start.addingTimeInterval(600).unixMilliseconds, categoryValue: 0,
            sourceName: "Apple Watch", sourceBundleID: "com.apple.health.preview",
            device: #"{"name":"Apple Watch","manufacturer":"Apple Inc."}"#,
            metadata: #"{"HKHeartRateEventThreshold":"\#(threshold) count/min"}"#))
      }
      let view = NavigationStack {
        HealthNotificationsContent(
          kind: .highHeartRate,
          state: .loaded([
            notification(daysAgo: 0, threshold: 120),
            notification(daysAgo: 9, hour: 22, threshold: 120),
            notification(daysAgo: 23, hour: 9, threshold: 130),
            notification(daysAgo: 61, hour: 16, threshold: 120),
          ]))
      }
      .previewFrame(width: 620, height: 520)
      assertMacSnapshot(of: view, appearance: appearance, named: "high-heart-rate-notifications")
    }

    // SettingsViewPreviews.swift, "Agents: on, with a log": Settings › Agents, a grouped `Form`.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func agentsPane(appearance: NSAppearance.Name) {
      let entries = [
        AgentAccessEntry(
          id: 5, date: Date(timeIntervalSince1970: 1_760_973_000), command: "open Steps",
          process: "Shortcuts, Siri or Spotlight"),
        AgentAccessEntry(
          id: 4, date: Date(timeIntervalSince1970: 1_760_972_520),
          command: "metric Steps --range W", process: "claude"),
        AgentAccessEntry(
          id: 3, date: Date(timeIntervalSince1970: 1_760_972_460), command: "summary",
          process: "claude"),
        AgentAccessEntry(
          id: 2, date: Date(timeIntervalSince1970: 1_760_965_200),
          command: "samples HeartRate --from 2025-10-13 --to 2025-10-20", process: "Codex"),
        AgentAccessEntry(
          id: 1, date: Date(timeIntervalSince1970: 1_760_961_600), command: "sleep --json",
          process: "zsh"),
      ]
      var state = AppFeature.State(isSignedIn: true)
      state.agentAccess = AgentAccessFeature.State(
        commandLineTool: URL(filePath: "/usr/local/bin/lil"), entries: entries, failure: nil,
        isEnabled: true, isLoading: false, logFailure: nil)
      let view = AgentAccessSettingsView(
        store: Store(initialState: state) {
          EmptyReducer<AppFeature.State, AppFeature.Action>()
            .ifLet(\.connectedAgents.$alert, action: \.connectedAgents.alert)
        }
      )
      .previewFrame(width: SettingsView.width, height: SettingsView.height)
      assertMacSnapshot(of: view, appearance: appearance, named: "agents-on-with-a-log")
    }

    // SyncFooterView.swift: the sidebar's sync footer through a first sync (851-2946).
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func syncFooter(appearance: NSAppearance.Name) {
      let states: [(String, SyncStatus)] = [
        ("downloading-very-large", .bootstrapping(.downloading(1_250_000, of: 48_731_204))),
        ("downloaded-saving-starts", .bootstrapping(.loading(0, of: 2_000_000))),
        ("saving-one-left", .bootstrapping(.loading(1_999_999, of: 2_000_000))),
        ("finishing-up", .bootstrapping(.finishing(2_000_000))),
        ("catching-up", .syncing(cursor: 2_000_000, head: 2_487_650)),
      ]
      for (name, status) in states {
        let view = SyncFooterView(status: status, retry: {})
          .frame(width: 260)
          .background(.background)
        assertMacSnapshot(of: view, appearance: appearance, named: "sync-footer-\(name)")
      }
    }
  }
#endif
