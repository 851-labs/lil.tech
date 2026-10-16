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
      case .uploading(let finished, let total, let records, let totalRecords):
        Label("Uploading your Health history", systemImage: "icloud.and.arrow.up")
          .foregroundStyle(.blue)
        UploadCounts(
          finishedTypes: finished, totalTypes: total, records: records, totalRecords: totalRecords)
      case .paused(let finished, let total, let records, let totalRecords):
        Label("Upload paused", systemImage: "pause.circle")
          .foregroundStyle(.orange)
        UploadCounts(
          finishedTypes: finished, totalTypes: total, records: records, totalRecords: totalRecords)
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

/// An upload's progress: by records once they've been counted, by types until then.
private struct UploadCounts: View {
  let finishedTypes: Int
  let totalTypes: Int
  let records: Int
  let totalRecords: Int?

  var body: some View {
    if let totalRecords {
      ProgressView(value: Double(records), total: Double(max(totalRecords, 1)))
      Text("\(records.formatted()) of \(totalRecords.formatted()) records")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    } else {
      ProgressView(value: Double(finishedTypes), total: Double(max(totalTypes, 1)))
      Text("\(finishedTypes) of \(totalTypes) types · \(records.formatted()) records")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}
