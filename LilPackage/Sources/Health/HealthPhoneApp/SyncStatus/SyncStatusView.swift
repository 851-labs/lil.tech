public import ComposableArchitecture
import HealthCatalog
import HealthUI
import HealthUpload
import LilAuth
public import SwiftUI

/// Sync Status: what's uploaded and what isn't, by category. The iPhone's main screen until
/// Summary (851-3211), which pushes it from its row or toolbar button, and runs the feature's
/// task while it shows.
public struct SyncStatusView: View {
  let store: StoreOf<SyncStatusFeature>

  public init(store: StoreOf<SyncStatusFeature>) {
    self.store = store
  }

  public var body: some View {
    List {
      Section {
        StatusHeader(store: store)
      }
      let heldBack = store.heldBack
      if !heldBack.isEmpty {
        Section {
          ForEach(heldBack) { type in
            LabeledContent(type.name) {
              Text(type.records.formatted())
                .monospacedDigit()
            }
          }
        } header: {
          Text("Not Uploaded")
        } footer: {
          Text("lil health tries these again later.")
        }
      }
      let categories = store.categories
      if !categories.isEmpty {
        Section {
          ForEach(categories) { category in
            CategoryRow(category: category)
          }
        } header: {
          Text("Categories")
        } footer: {
          Text(
            "If a category stays empty, check Settings › Privacy & Security › Health › lil health."
          )
        }
      }
    }
    .navigationTitle("Sync Status")
  }
}

private struct StatusHeader: View {
  let store: StoreOf<SyncStatusFeature>
  /// From dependencies, so snapshot catalogs fix it: the last upload's "5 minutes ago".
  @Dependency(\.date) var date

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      let status = store.status
      SyncStatusLabel(status: status)
      switch status {
      case .needsConsent:
        message(status)
        Button("Review Consent") { store.send(.reviewConsentButtonTapped) }
          .buttonStyle(.borderedProminent)
      case .loading:
        EmptyView()
      case .needsHealthAccess:
        message(status)
        Button("Review Access") { store.send(.reviewHealthAccessButtonTapped) }
          .buttonStyle(.borderedProminent)
      case .offline, .storageFull, .failed:
        message(status)
        Button("Try Again") { store.send(.retryButtonTapped) }
          .buttonStyle(.bordered)
      case .uploading(_, _, let records, let totalRecords):
        UploadCounts(records: records, totalRecords: totalRecords)
      case .paused(_, _, let records, let totalRecords):
        UploadCounts(records: records, totalRecords: totalRecords)
        message(status)
        Button("Continue") { store.send(.retryButtonTapped) }
          .buttonStyle(.bordered)
      case .upToDate(let lastUpload):
        if let lastUpload {
          // Updated every minute while the screen is open.
          TimelineView(.everyMinute) { _ in
            let ago = Date.AnchoredRelativeFormatStyle(anchor: lastUpload, presentation: .named)
            Text("Last upload \(ago.format(date.now))")
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
      }
    }
    .font(.headline)
    .padding(.vertical, 4)
  }

  @ViewBuilder private func message(_ status: SyncStatusFeature.State.Status) -> some View {
    if let message = status.message {
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }
}

/// A status's symbol and title, in its color: the status screen's header, and Summary's row
/// (851-3211).
struct SyncStatusLabel: View {
  let status: SyncStatusFeature.State.Status

  var body: some View {
    switch status {
    case .needsConsent:
      Label("Not uploading", systemImage: "hand.raised")
        .foregroundStyle(.secondary)
    case .loading:
      Label("Checking…", systemImage: "arrow.triangle.2.circlepath")
    case .needsHealthAccess:
      Label("Health access needed", systemImage: "heart.text.square")
        .foregroundStyle(.pink)
    case .offline:
      Label("Paused", systemImage: "wifi.slash")
        .foregroundStyle(.orange)
    case .storageFull:
      Label("Storage full", systemImage: "externaldrive.badge.exclamationmark")
        .foregroundStyle(.red)
    case .failed:
      Label("Upload failed", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    case .uploading:
      Label("Uploading your Health history", systemImage: "icloud.and.arrow.up")
        .foregroundStyle(.blue)
    case .paused:
      Label("Upload paused", systemImage: "pause.circle")
        .foregroundStyle(.orange)
    case .upToDate:
      Label("Up to date", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    }
  }
}

extension SyncStatusFeature.State.Status {
  /// What the status says under its title, if anything: why nothing's uploading, or what
  /// happens next.
  var message: String? {
    switch self {
    case .needsConsent: "lil health needs your consent to upload your Health data."
    case .needsHealthAccess: "lil health needs access to your Health data to upload it."
    case .offline: "Uploading continues when you're back online."
    case .storageFull: "Your lil account is full. What's already uploaded is safe."
    case .failed(let reason): reason
    case .paused: "It'll continue in the background."
    case .loading, .uploading, .upToDate: nil
    }
  }
}

private struct CategoryRow: View {
  let category: SyncStatusFeature.CategoryProgress

  var body: some View {
    HStack {
      HealthCategoryLabel(category.category)
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
/// mentioned (`ItemsCopy`, which the Mac's sync footer shares).
enum UploadCopy {
  /// "1,234,567 items left" once counted. Otherwise, and when the estimate runs out (it counts
  /// samples, and some upload as several items), what's gone up: "630,368 items uploaded".
  /// Counting can fail for a type, or be paused, so there's no "Counting…" to get stuck on.
  static func left(records: Int, totalRecords: Int?) -> String {
    if let totalRecords, totalRecords > records {
      return ItemsCopy.left(totalRecords - records)
    }
    return records == 1 ? "1 item uploaded" : "\(records.formatted()) items uploaded"
  }
}

/// An upload's progress: by records once they've been counted. Until then the bar is
/// indeterminate, since the share of types done says little (empty types finish first), and a
/// bar by types would jump back once the records are counted.
struct UploadCounts: View {
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
