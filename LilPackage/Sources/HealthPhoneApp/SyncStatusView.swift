public import ComposableArchitecture
import HealthCatalog
import HealthUpload
public import SwiftUI

public struct SyncStatusView: View {
  let store: StoreOf<SyncStatusFeature>

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
          Button("Sign Out", role: .destructive) { store.send(.signOutButtonTapped) }
        } footer: {
          Text(
            "Health doesn't tell apps what you turned off. If a category stays empty, check its access in Settings."
          )
        }
      }
      .navigationTitle("lil health")
    }
    .task { await store.send(.task).finish() }
  }
}

private struct StatusHeader: View {
  let store: StoreOf<SyncStatusFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch store.status {
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
      case .failed(let reason):
        Label("Upload failed", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
        Text(reason)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Button("Try Again") { store.send(.retryButtonTapped) }
          .buttonStyle(.bordered)
      case .uploading(let finished, let total, let records):
        Label("Uploading your Health history", systemImage: "icloud.and.arrow.up")
          .foregroundStyle(.blue)
        ProgressView(value: Double(finished), total: Double(max(total, 1)))
        Text("\(finished) of \(total) types · \(records.formatted()) records")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      case .paused(let finished, let total, let records):
        Label("Upload paused", systemImage: "pause.circle")
          .foregroundStyle(.orange)
        ProgressView(value: Double(finished), total: Double(max(total, 1)))
        Text("\(finished) of \(total) types · \(records.formatted()) records")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
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
