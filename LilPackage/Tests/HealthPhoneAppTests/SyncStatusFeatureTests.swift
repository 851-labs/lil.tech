import ComposableArchitecture
import Foundation
import HealthCatalog
import HealthKitAccess
import HealthPhoneApp
import HealthUpload
import LilAuth
import Testing

// Synthetic data only (AGENTS.md).
private let steps = "HKQuantityTypeIdentifierStepCount"
private let energy = "HKQuantityTypeIdentifierActiveEnergyBurned"
private let sleep = "HKCategoryTypeIdentifierSleepAnalysis"
private let lastUpload = Date(timeIntervalSince1970: 1_760_400_000)

private func progress(
  _ types: [String: HealthBackfill.TypeProgress], running: Bool = false, failure: String? = nil,
  offline: Bool = false
) -> HealthBackfill.Progress {
  HealthBackfill.Progress(
    finishedTypes: types.values.filter(\.isDone).count, totalTypes: types.count,
    uploadedRecords: types.values.map(\.uploadedRecords).reduce(0, +), isRunning: running,
    failure: failure, isOffline: offline, types: types, lastUploadAt: lastUpload)
}

@MainActor
struct SyncStatusFeatureTests {
  @Test
  func statusFollowsTheProgress() {
    typealias State = SyncStatusFeature.State
    let done = HealthBackfill.TypeProgress(isDone: true, uploadedRecords: 10)
    let notYet = HealthBackfill.TypeProgress(isDone: false, uploadedRecords: 0)
    #expect(State().status == .loading)
    #expect(
      State(progress: progress([steps: done]), needsHealthAccess: true).status
        == .needsHealthAccess)
    #expect(
      State(progress: progress([steps: done, sleep: notYet], running: true)).status
        == .uploading(finishedTypes: 1, totalTypes: 2, records: 10))
    #expect(State(progress: progress([steps: done])).status == .upToDate(lastUpload: lastUpload))
    #expect(
      State(progress: progress([steps: notYet], failure: "Offline", offline: true)).status
        == .offline)
    #expect(
      State(progress: progress([steps: notYet], failure: "HTTP 503")).status
        == .failed("HTTP 503"))
  }

  @Test
  func categoriesAddUpTheirTypes() {
    let state = SyncStatusFeature.State(
      progress: progress([
        steps: .init(isDone: true, uploadedRecords: 10),
        energy: .init(isDone: false, uploadedRecords: 5),
        sleep: .init(isDone: true, uploadedRecords: 2),
      ]))
    #expect(
      state.categories.map {
        [$0.category.rawValue, "\($0.finishedTypes)/\($0.totalTypes)", "\($0.records)"]
      }
        == [["activity", "1/2", "15"], ["sleep", "1/1", "2"]])
  }

  @Test
  func followsTheBackfill() async throws {
    let store = TestStore(initialState: SyncStatusFeature.State()) {
      SyncStatusFeature()
    } withDependencies: {
      $0.healthAuthorization.needsRequest = { false }
    }
    store.exhaustivity = .off

    let task = await store.send(.task)
    await store.receive(\.healthAccessChecked)
    await store.receive(\.progressChanged)
    #expect(store.state.progress?.totalTypes == 0)
    await task.cancel()
  }

  @Test
  func buttons() async {
    let opened = LockIsolated<[URL]>([])
    let signedOut = LockIsolated(false)
    let store = TestStore(initialState: SyncStatusFeature.State()) {
      SyncStatusFeature()
    } withDependencies: {
      $0.openURL = OpenURLEffect { url in
        opened.withValue { $0.append(url) }
        return true
      }
      $0.auth.signOut = { signedOut.setValue(true) }
    }

    await store.send(.openSettingsButtonTapped).finish()
    #expect(opened.value == [URL(string: "app-settings:")!])
    await store.send(.signOutButtonTapped).finish()
    #expect(signedOut.value)
    await store.send(.reviewHealthAccessButtonTapped)
    await store.receive(\.delegate.reviewHealthAccess)
    await store.send(.retryButtonTapped).finish()
  }
}
