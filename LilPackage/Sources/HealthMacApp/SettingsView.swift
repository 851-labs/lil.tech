public import ComposableArchitecture
import LilAuth
public import SwiftUI

/// The app's Settings window (⌘, or the account menu's Account Settings…), a tab per pane: the
/// account's, for now (851-2717). It reads the app's store, so it works whether or not the main
/// window is open, and an export keeps going when it closes.
public struct SettingsView: View {
  let store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  /// The window's width, which every pane shares.
  static let width: CGFloat = 480

  public var body: some View {
    TabView {
      AccountSettingsView(store: store)
        .tabItem { Label("Account", systemImage: "person.crop.circle") }
    }
    .frame(width: Self.width)
  }
}

/// The account's pane: its sign-in methods and exporting its data, or, signed out, how to get
/// them.
struct AccountSettingsView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    if store.isSignedIn == true {
      let account = store.scope(\.account, action: \.account)
      Form {
        SignInMethodsSection(store: account.scope(\.signInMethods, action: \.signInMethods))
        DataExportSection(store: account.scope(\.dataExport, action: \.dataExport))
      }
      .formStyle(.grouped)
      .frame(height: 380)
    } else {
      ContentUnavailableView {
        Label("Not Signed In", systemImage: "person.crop.circle")
      } description: {
        Text("Sign in to lil health to see how you sign in and to export your data.")
      }
      .frame(height: 260)
    }
  }
}

/// Exporting the account's data: a button, then how the export is going.
struct DataExportSection: View {
  let store: StoreOf<DataExportFeature>

  var body: some View {
    Section {
      switch store.status {
      case .idle, .failed:
        Button("Export Data…") { store.send(.exportButtonTapped) }
      case .preparing:
        HStack {
          ProgressView()
            .controlSize(.small)
          Text("Preparing your export…")
          Spacer()
          Button("Cancel") { store.send(.cancelButtonTapped) }
        }
      case .downloading(let share):
        HStack {
          ProgressView(value: share) {
            Text("Downloading…")
          } currentValueLabel: {
            Text(share.formatted(.percent.precision(.fractionLength(0))))
          }
          Button("Cancel") { store.send(.cancelButtonTapped) }
        }
      case .saving:
        Text("Choose where to save your export.")
          .foregroundStyle(.secondary)
      case .saved(let url):
        HStack {
          Label {
            Text(url.lastPathComponent)
              .lineLimit(1)
              .truncationMode(.middle)
          } icon: {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
          }
          Spacer()
          Button("Show in Finder") { store.send(.showInFinderButtonTapped) }
        }
      }
    } header: {
      Text("Your Data")
    } footer: {
      if case .failed(let message) = store.status {
        Text(message)
          .foregroundStyle(.red)
      } else {
        Text(
          "A copy of everything in your account, as an archive: your account details, synced Health records and attachments. One export a day."
        )
      }
    }
  }
}
