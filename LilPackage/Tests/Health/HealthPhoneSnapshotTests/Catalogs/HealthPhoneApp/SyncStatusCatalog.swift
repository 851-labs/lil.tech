#if os(iOS)
  import ComposableArchitecture
  import Foundation
  import HealthCatalog
  @testable import HealthPhoneApp
  import HealthUpload
  import SwiftUI
  import Testing

  // Sync Status, the iPhone app's main screen (`SyncStatusView`): its states, from synthetic
  // upload progress at `previewNow`. Synthetic data only.

  extension PhoneSnapshotTests {
    @Test(arguments: syncStatusCatalog.selectedStates)
    func syncStatus(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let syncStatusCatalog = StateCatalog(
    phone: "Sync Status",
    states: [
      CatalogState("Checking") {
        statusView(SyncStatusFeature.State())
      },
      CatalogState("Checking Health access on a new install") {
        statusView(SyncStatusFeature.State(progress: progress(done: 0), needsHealthAccess: nil))
      },
      CatalogState("Health access needed") {
        statusView(SyncStatusFeature.State(progress: progress(done: 0), needsHealthAccess: true))
      },
      CatalogState("Uploading") {
        statusView(SyncStatusFeature.State(progress: progress(done: 40, running: true)))
      },
      CatalogState("Uploading, counted") {
        statusView(
          SyncStatusFeature.State(
            progress: {
              var counted = progress(done: 40, running: true)
              counted.totalRecords = 1_284_000
              return counted
            }()))
      },
      CatalogState("Upload paused, counted") {
        statusView(
          SyncStatusFeature.State(
            progress: {
              var counted = progress(done: 60)
              counted.totalRecords = 1_284_000
              return counted
            }()))
      },
      CatalogState("Up to date") {
        statusView(SyncStatusFeature.State(progress: progress(done: .max)))
      },
      CatalogState("Paused offline") {
        statusView(
          SyncStatusFeature.State(
            progress: progress(
              done: 25, failure: "The Internet connection appears to be offline.", offline: true)))
      },
      CatalogState("Failed") {
        statusView(
          SyncStatusFeature.State(
            progress: progress(done: 25, failure: "The server answered HTTP 503")))
      },
      CatalogState("Storage full") {
        statusView(
          SyncStatusFeature.State(
            progress: progress(
              done: 70, failure: "Your lil account's storage is full", storageFull: true)))
      },
      CatalogState("Upload paused") {
        statusView(SyncStatusFeature.State(progress: progress(done: 60)))
      },
      // Every type is empty: no data, or no access.
      CatalogState("Nothing to upload") {
        statusView(
          SyncStatusFeature.State(
            progress: {
              var progress = progress(done: .max)
              progress.types = progress.types.mapValues { _ in
                .init(isDone: true, uploadedRecords: 0)
              }
              progress.uploadedRecords = 0
              progress.lastUploadAt = nil
              return progress
            }()))
      },
      CatalogState("Not uploading without consent") {
        statusView(SyncStatusFeature.State(progress: progress(done: 70)), consented: false)
      },
    ])

  /// Synthetic progress: every standard type, the first `done` of them uploaded, the last upload
  /// five minutes before `previewNow`.
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
      lastUploadAt: done > 0 ? previewNow.addingTimeInterval(-300) : nil)
  }

  @MainActor
  private func statusView(_ state: SyncStatusFeature.State, consented: Bool = true) -> some View {
    state.$consentedPolicyVersion.withLock {
      $0 = consented ? HealthConsentClient.policyVersion : nil
    }
    // `EmptyReducer`: the view's task would replace the state with the real backfill's.
    // `ifLet`: closing an alert clears it, as the feature does.
    return SyncStatusView(
      store: Store(initialState: state) {
        EmptyReducer<SyncStatusFeature.State, SyncStatusFeature.Action>()
          .ifLet(\.$alert, action: \.alert)
      })
  }
#endif
