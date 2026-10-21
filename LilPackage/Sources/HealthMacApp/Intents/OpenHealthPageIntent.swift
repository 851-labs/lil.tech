public import AppIntents
import Dependencies
public import Foundation

/// Opens a page of lil health for Mac from Shortcuts, Siri or Spotlight (851-2892): brings the
/// main window forward and shows Summary, Health Details, a category, or a data type in its
/// category. Only while command-line and agent access is on, like every app action.
public struct OpenHealthPageIntent: OpenIntent {
  public static let title: LocalizedStringResource = "Open in lil health"
  public static let description = IntentDescription(
    "Opens Summary, Health Details, a Health category or a data type in lil health. Needs Allow command-line and agent access, in lil health's Settings › Agents."
  )
  /// In the background until access is checked, so the app only comes forward when it's on.
  public static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

  @Parameter(title: "Page")
  public var target: HealthPage

  public init() {}

  public init(target: HealthPage) {
    self.target = target
  }

  public static var parameterSummary: some ParameterSummary {
    Summary("Open \(\.$target) in lil health")
  }

  public func perform() async throws -> some IntentResult {
    _ = try await HealthAppIntents.perform(.open(target)) {
      if systemContext.currentMode.canContinueInForeground {
        try await continueInForeground(alwaysConfirm: false)
      }
    }
    return .result()
  }
}

/// What every one of the app's intents does (851-2892), so they check access the same way.
enum HealthAppIntents {
  /// The access log's process for intents: App Intents doesn't say which one called.
  static let process = "Shortcuts, Siri or Spotlight"

  /// Checks command-line and agent access and logs the action (`AgentAccessStore.authorize`),
  /// then runs `beforeAction` (bringing the app forward, for Open) and asks the app. Every time,
  /// Siri's and Spotlight's included: an intent can't tell a person from an agent's shortcut.
  /// While access is off it does nothing else, and fails with how to turn it on.
  static func perform(
    _ action: HealthAppAction, beforeAction: () async throws -> Void = {}
  ) async throws -> HealthAppActionResult {
    @Dependency(\.agentAccess) var agentAccess
    @Dependency(\.healthAppActions) var healthAppActions
    do {
      try await agentAccess.authorize(action.command, process)
    } catch {
      // `AgentAccessError.off`'s message, or why the setting couldn't be read.
      throw HealthAppIntentError(error)
    }
    // App Intents' own errors (the app couldn't come forward) and the app's
    // (`HealthAppActionError`, which says itself what Shortcuts shows) pass through as they are.
    try await beforeAction()
    return try await healthAppActions.perform(action)
  }
}

/// An intent's failure, with the message Shortcuts, Siri and Spotlight show.
struct HealthAppIntentError: Error, Equatable, LocalizedError,
  CustomLocalizedStringResourceConvertible
{
  let message: String

  init(_ error: any Error) {
    message = error.localizedDescription
  }

  var errorDescription: String? { message }

  var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// The module's intents and entities, which the app's own `AppIntentsPackage` includes, so the
/// system finds them in the app. App Shortcuts can't come from a package: the app's metadata
/// leaves a package's out, so the app target has them (`LilHealthAppShortcuts`).
public struct HealthMacAppIntents: AppIntentsPackage {}
