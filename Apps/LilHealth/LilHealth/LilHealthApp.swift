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
