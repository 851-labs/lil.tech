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
    #if DEBUG
      ScriptedSignOut.start()
    #endif
  }

  var body: some Scene {
    // One window: the app has one store, and one session to follow.
    Window("lil health", id: AppView.windowID) {
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
      // A metric's or Sleep's range and period, in the View menu.
      PeriodCommands()
    }
    // lil health › Settings… (⌘,), with Sign Out in its Account pane (851-3096).
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

#if DEBUG
  /// Signs a Debug build out when a script asks (851-3096), so a scripted run's session doesn't
  /// outlive it, without Accessibility access or clicking through Settings: a distributed
  /// notification whose object is the app's pid, so it reaches that one process.
  ///
  /// ```sh
  /// osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("tech.lil.health.debug.signOut", "'$pid'", $(), true)'
  /// ```
  ///
  /// Signing out this way doesn't ask first, as Settings' Sign Out… does. Release builds don't
  /// listen.
  private enum ScriptedSignOut {
    static func start() {
      DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("tech.lil.health.debug.signOut"),
        object: String(ProcessInfo.processInfo.processIdentifier), queue: nil
      ) { _ in
        // Nonisolated: the session's updates bring the store to signed out.
        Task {
          @Dependency(\.auth) var auth
          await auth.signOut()
        }
      }
    }
  }
#endif
