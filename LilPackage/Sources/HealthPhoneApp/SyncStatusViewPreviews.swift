import ComposableArchitecture
import Foundation
import HealthCatalog
import HealthUpload
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md).

/// Synthetic progress: every standard type, the first `done` of them uploaded.
private func progress(
  done: Int, failure: String? = nil, offline: Bool = false, storageFull: Bool = false,
  running: Bool = false
) -> HealthBackfill.Progress {
  let types = HealthBackfillType.all(availableOn: .ios(26)).map(\.id)
  let byType = Dictionary(
    uniqueKeysWithValues: types.enumerated().map { index, id in
      (
        id,
        HealthBackfill.TypeProgress(
          isDone: index < done, uploadedRecords: index < done ? 1_200 + index * 37 : 0)
      )
    })
  return HealthBackfill.Progress(
    finishedTypes: min(done, types.count), totalTypes: types.count,
    uploadedRecords: byType.values.map(\.uploadedRecords).reduce(0, +), isRunning: running,
    failure: failure, isOffline: offline, isStorageFull: storageFull, types: byType,
    lastUploadAt: done > 0 ? Date(timeIntervalSinceNow: -300) : nil)
}

@MainActor
private func statusView(_ state: SyncStatusFeature.State) -> some View {
  // `EmptyReducer`: the view's task would replace the state with the real backfill's.
  SyncStatusView(store: Store(initialState: state) { EmptyReducer() })
}

#Preview("Checking") {
  statusView(SyncStatusFeature.State())
}

#Preview("Health access needed") {
  statusView(SyncStatusFeature.State(progress: progress(done: 0), needsHealthAccess: true))
}

#Preview("Uploading") {
  statusView(SyncStatusFeature.State(progress: progress(done: 40, running: true)))
}

#Preview("Up to date") {
  statusView(SyncStatusFeature.State(progress: progress(done: .max)))
}

#Preview("Paused offline") {
  statusView(
    SyncStatusFeature.State(
      progress: progress(
        done: 25, failure: "The Internet connection appears to be offline.", offline: true)))
}

#Preview("Failed") {
  statusView(
    SyncStatusFeature.State(progress: progress(done: 25, failure: "The server answered HTTP 503")))
}

#Preview("Storage full") {
  statusView(
    SyncStatusFeature.State(
      progress: progress(
        done: 70, failure: "Your lil account's storage is full", storageFull: true)))
}

#Preview("Upload paused") {
  statusView(SyncStatusFeature.State(progress: progress(done: 60)))
}

#Preview("Nothing to upload") {
  // Every type is empty: no data, or no access.
  statusView(
    SyncStatusFeature.State(
      progress: {
        var progress = progress(done: .max)
        progress.types = progress.types.mapValues { _ in .init(isDone: true, uploadedRecords: 0) }
        progress.uploadedRecords = 0
        progress.lastUploadAt = nil
        return progress
      }()))
}

#Preview("Delete account?") {
  statusView(
    SyncStatusFeature.State(progress: progress(done: .max), alert: .confirmDeletion))
}

#Preview("Deleting account") {
  statusView(SyncStatusFeature.State(progress: progress(done: .max), isDeletingAccount: true))
}

#Preview("Deleting failed") {
  statusView(
    SyncStatusFeature.State(
      progress: progress(done: .max),
      alert: .deletionFailed("It isn't possible right now. Please try again later.")))
}
