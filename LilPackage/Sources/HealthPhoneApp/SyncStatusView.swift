public import ComposableArchitecture
import HealthCatalog
import HealthUpload
public import SwiftUI

public struct SyncStatusView: View {
  @Bindable var store: StoreOf<SyncStatusFeature>

  public init(store: StoreOf<SyncStatusFeature>) {
    self.store = store
  }

  public var body: some View {
    NavigationStack {
      List {
        Section {
          StatusHeader(store: store)
        }
        let categories = store.categories
        if !categories.isEmpty {
          Section("Categories") {
            ForEach(categories) { category in
              CategoryRow(category: category)
            }
          }
        }
        Section {
          Button("Health Access in Settings") { store.send(.openSettingsButtonTapped) }
          Link("Privacy Policy", destination: privacyPolicy)
          if store.hasConsent {
            Button("Withdraw Consent") { store.send(.withdrawConsentButtonTapped) }
          }
          Button("Sign Out") { store.send(.signOutButtonTapped) }
          Button("Delete Account", role: .destructive) {
            store.send(.deleteAccountButtonTapped)
          }
        } footer: {
          Text(
            "Health doesn't tell apps what you turned off. If a category stays empty, check its access in Settings."
          )
        }
        #if targetEnvironment(simulator)
          SyntheticHealthSection()
        #endif
      }
      .navigationTitle("lil health")
      .disabled(store.isDeletingAccount || store.isWithdrawingConsent)
      .overlay {
        if store.isDeletingAccount || store.isWithdrawingConsent {
          ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            ProgressView(
              store.isDeletingAccount ? "Deleting your account…" : "Withdrawing your consent…")
          }
        }
      }
      .alert($store.scope(\.alert, action: \.alert))
    }
    .task { await store.send(.task).finish() }
  }
}

private struct StatusHeader: View {
  let store: StoreOf<SyncStatusFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch store.status {
      case .needsConsent:
        Label("Not uploading", systemImage: "hand.raised")
          .foregroundStyle(.secondary)
        Text(
          "lil health uploads your Health data only with your consent. Anything uploaded before stays in your account until you delete it."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        Button("Review Consent") { store.send(.reviewConsentButtonTapped) }
          .buttonStyle(.borderedProminent)
      case .loading:
        Label("Checking…", systemImage: "arrow.triangle.2.circlepath")
      case .needsHealthAccess:
        Label("Health access needed", systemImage: "heart.text.square")
          .foregroundStyle(.pink)
        Text("lil health can't upload what Health hasn't shared with it.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Button("Review Access") { store.send(.reviewHealthAccessButtonTapped) }
          .buttonStyle(.borderedProminent)
      case .offline:
        Label("Paused", systemImage: "wifi.slash")
          .foregroundStyle(.orange)
        Text("Uploading continues when you're back online.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Button("Try Again") { store.send(.retryButtonTapped) }
          .buttonStyle(.bordered)
      case .storageFull:
        Label("Storage full", systemImage: "externaldrive.badge.exclamationmark")
          .foregroundStyle(.red)
        Text(
          "Your lil account is full, so new Health data isn't uploaded. Everything uploaded so far is safe."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        Button("Try Again") { store.send(.retryButtonTapped) }
          .buttonStyle(.bordered)
      case .failed(let reason):
        Label("Upload failed", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
        Text(reason)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Button("Try Again") { store.send(.retryButtonTapped) }
          .buttonStyle(.bordered)
      case .uploading(_, _, let records, let totalRecords):
        Label("Uploading your Health history", systemImage: "icloud.and.arrow.up")
          .foregroundStyle(.blue)
        UploadCounts(records: records, totalRecords: totalRecords)
      case .paused(_, _, let records, let totalRecords):
        Label("Upload paused", systemImage: "pause.circle")
          .foregroundStyle(.orange)
        UploadCounts(records: records, totalRecords: totalRecords)
        Text("It continues in the background, or now.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Button("Continue") { store.send(.retryButtonTapped) }
          .buttonStyle(.bordered)
      case .upToDate(let lastUpload):
        Label("Up to date", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        if let lastUpload {
          // Updated every minute while the screen is open.
          TimelineView(.everyMinute) { _ in
            Text("Last upload \(lastUpload.formatted(.relative(presentation: .named)))")
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
      }
    }
    .font(.headline)
    .padding(.vertical, 4)
  }
}

private struct CategoryRow: View {
  let category: SyncStatusFeature.CategoryProgress

  var body: some View {
    HStack {
      Label(category.category.name, systemImage: category.category.symbolName)
      Spacer()
      Text(category.records.formatted())
        .foregroundStyle(.secondary)
        .monospacedDigit()
      if category.isDone {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .accessibilityLabel("Uploaded")
      } else {
        ProgressView(
          value: Double(category.finishedTypes), total: Double(category.totalTypes)
        )
        .progressViewStyle(.circular)
        .controlSize(.small)
        .accessibilityLabel("Uploading")
      }
    }
  }
}

/// How an upload's progress reads, here and in the system's task UI: what's left, as backup apps
/// say it ("321 items left" in Google Photos, items remaining in iCloud Photos), with the bar or
/// ring showing the share done. Records are "items", and the types they come in aren't
/// mentioned.
enum UploadCopy {
  /// "1,234,567 items left" once counted. Otherwise, and when the estimate runs out (it counts
  /// samples, and some upload as several items), what's gone up: "630,368 items uploaded".
  /// Counting can fail for a type, or be paused, so there's no "Counting…" to get stuck on.
  static func left(records: Int, totalRecords: Int?) -> String {
    if let totalRecords, totalRecords > records {
      let left = totalRecords - records
      return left == 1 ? "1 item left" : "\(left.formatted()) items left"
    }
    return records == 1 ? "1 item uploaded" : "\(records.formatted()) items uploaded"
  }
}

/// An upload's progress: by records once they've been counted. Until then the bar is
/// indeterminate, since the share of types done says little (empty types finish first), and a
/// bar by types would jump back once the records are counted.
private struct UploadCounts: View {
  let records: Int
  let totalRecords: Int?

  var body: some View {
    Group {
      if let totalRecords {
        ProgressView(value: Double(records), total: Double(max(totalRecords, 1)))
      } else {
        ProgressView()
          .progressViewStyle(.linear)
      }
    }
    Text(UploadCopy.left(records: records, totalRecords: totalRecords))
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .monospacedDigit()
  }
}
