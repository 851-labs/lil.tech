public import AppIntents
import Foundation

/// Syncs lil health for Mac from Shortcuts, Siri or Spotlight (851-2893): pulls the account's
/// changes from the server now, and answers once caught up, with the sync's error, or that it's
/// still syncing after a minute. The Mac never uploads Health data: the iPhone does. Only while
/// access on this Mac is on, like every app action.
public struct SyncHealthDataIntent: AppIntent {
  public static let title: LocalizedStringResource = "Sync lil health"
  public static let description = IntentDescription(
    "Gets the latest Health data from your iPhone. Needs Allow access on this Mac, in lil health's Settings › Agents."
  )
  /// Never brings a running app's window forward. One that wasn't running is launched to ask,
  /// with its window, as for every intent of a SwiftUI `Window` app.
  public static let supportedModes: IntentModes = .background

  public init() {}

  /// How it went, as text, without a dialog (851-2943): Shortcuts waits for a dialog's Done
  /// before it goes on, so one would stop `shortcuts run` until someone clicks it. A shortcut can
  /// show the text, and errors still show.
  public func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let result = try await HealthAppIntents.perform(.sync)
    return .result(value: Self.message(for: result))
  }

  /// What the intent returns once the app has answered.
  static func message(for result: HealthAppActionResult) -> String {
    switch result {
    case .stillSyncing: "Still syncing. lil health will finish in the background."
    case .synced: "lil health is up to date."
    case .done, .exported: "Done."
    }
  }
}
