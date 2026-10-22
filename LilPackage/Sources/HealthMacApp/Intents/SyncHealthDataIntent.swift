public import AppIntents
import Foundation

/// Syncs lil health for Mac from Shortcuts, Siri or Spotlight (851-2893): pulls the account's
/// changes from the server now, and answers once caught up, with the sync's error, or that it's
/// still syncing after a minute. The Mac never uploads Health data: the iPhone does. Only while
/// command-line and agent access is on, like every app action.
public struct SyncHealthDataIntent: AppIntent {
  public static let title: LocalizedStringResource = "Sync lil health"
  public static let description = IntentDescription(
    "Gets the latest Health data your iPhone uploaded to lil health. It can't make your iPhone upload: lil health on the iPhone does that by itself. Needs Allow command-line and agent access, in lil health's Settings › Agents."
  )
  /// Never brings a running app's window forward. One that wasn't running is launched to ask,
  /// with its window, as for every intent of a SwiftUI `Window` app.
  public static let supportedModes: IntentModes = .background

  public init() {}

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    let result = try await HealthAppIntents.perform(.sync)
    return .result(dialog: "\(Self.dialog(for: result))")
  }

  /// What Shortcuts, Siri and Spotlight say once the app has answered.
  static func dialog(for result: HealthAppActionResult) -> String {
    switch result {
    case .stillSyncing: "Still syncing. lil health will finish in the background."
    case .synced: "lil health is up to date."
    case .done, .exported: "Done."
    }
  }
}
