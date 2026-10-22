#if os(macOS)
  import AppKit
  import ComposableArchitecture
  import DependenciesTestSupport
  import Foundation
  import HealthAgentAccess
  import HealthDatabase
  import LilAuth
  import LilSync
  @testable import HealthMacApp
  @testable import HealthPages
  import SQLiteData
  import SnapshotTesting
  import SwiftUI
  import Testing

  // Preview states of lil health for Mac, light and dark (851-2931). Each builds the same view as
  // the `#Preview` it names, from fixed dates. Synthetic data only. State catalogs (`Catalogs/`,
  // 851-2949) add their tests to this suite, and replace these as screens migrate.

  // Serialized: a snapshot runs the main run loop, where another could start and change the
  // app's appearance. Views that read the database, the date or the calendar get the catalogs'
  // (851-2950).
  @MainActor
  @Suite(
    .serialized,
    .dependencies {
      // Before the catalog database is built, which formats dates.
      fixTimeZoneAndLocale()
      $0.defaultDatabase = catalogDatabase
      $0.date.now = previewNow
      $0.calendar = previewCalendar
      $0.timeZone = previewCalendar.timeZone
      $0.locale = previewCalendar.locale!
    })
  struct MacSnapshotTests {
    init() {
      // Before any test builds its dates.
      prepareSnapshotEnvironment()
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
  }
#endif
