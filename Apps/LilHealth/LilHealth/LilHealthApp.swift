import AppIntents
import ComposableArchitecture
import HealthMacApp
import LilAuth
import LilCLIInstaller
import LilUpdates
import SwiftUI

@main
struct LilHealthApp: App {
  static let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  #if !DEBUG
    // Debug builds (from Xcode, or scripted against a preview) don't update themselves to the
    // released app.
    @State private var updater = AppUpdater()
  #endif

  init() {
    prepareDependencies {
      $0.authDevice = .current(app: "health-mac")
      $0.authenticateAPI()
      $0.keepSettingsPerServer()
      // Now, so an intent that launched the app waits for sign-in from launch.
      $0.healthAppActions = .live
      do {
        try $0.prepareHealthSync()
      } catch {
        // Nothing works without the local database.
        fatalError("Couldn't open the local database: \(error)")
      }
    }
    // Here rather than in the main window, so the session is followed while it's closed too,
    // for the Settings window.
    Task { await Self.store.send(.task).finish() }
    // Replaces an installed `lil` older than the bundled one, after an update.
    CommandLineToolRefresh.start()
  }

  var body: some Scene {
    // One window: the app has one store, and one session to follow.
    Window("lil health", id: "main") {
      AppView(store: Self.store)
        // Offers to update an installed `lil` only an administrator can replace.
        .refreshesCommandLineTool()
    }
    .commands {
      #if !DEBUG
        CheckForUpdatesCommands(updater: updater)
      #endif
      // Installs the `lil` command, bundled in Contents/MacOS.
      InstallCommandLineToolCommands()
      CommandGroup(after: .appSettings) {
        SignOutCommand(store: Self.store)
      }
      // A metric's or Sleep's range and period, in the View menu.
      PeriodCommands()
    }
    // lil health › Settings… (⌘,).
    Settings {
      SettingsView(store: Self.store)
    }
    .defaultSize(width: SettingsView.minWidth, height: SettingsView.minHeight)
  }
}

/// The intents, entities and App Shortcuts `HealthMacApp` provides (851-2892): the app's App
/// Intents metadata includes a package's only through the app's own `AppIntentsPackage`.
struct LilHealthAppIntents: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] { [HealthMacAppIntents.self] }
}

/// Phrases Siri and Spotlight offer without any setup (851-2892, 851-2893). Here rather than in
/// `HealthMacApp`, with the intents: the app's App Intents metadata leaves out a package's App
/// Shortcuts. None for Export lil health Data (851-2894): an export is something a shortcut passes
/// on, not something people ask Siri for.
struct LilHealthAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenHealthPageIntent(),
      phrases: [
        "Open \(\.$target) in \(.applicationName)",
        "Show \(\.$target) in \(.applicationName)",
      ],
      shortTitle: "Open Page",
      systemImageName: "heart.text.square"
    )
    AppShortcut(
      intent: SyncHealthDataIntent(),
      phrases: ["Sync \(.applicationName)"],
      shortTitle: "Sync",
      systemImageName: "arrow.triangle.2.circlepath"
    )
  }
}

/// Sign Out in the app menu. A view, so it follows the store's session as it changes.
private struct SignOutCommand: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    Button("Sign Out") { store.send(.signOutButtonTapped) }
      .disabled(store.isSignedIn != true)
  }
}
