import ComposableArchitecture
import LilAuth
import SwiftUI

/// Account settings, in a sheet from the account menu: sign-in methods and exporting data.
struct AccountSheet: View {
  let store: StoreOf<AccountFeature>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      Form {
        SignInMethodsSection(store: store.scope(\.signInMethods, action: \.signInMethods))
        DataExportSection(store: store.scope(\.dataExport, action: \.dataExport))
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        if store.dataExport.isBusy {
          Text("Closing stops the export.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(width: 460, height: 480)
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
