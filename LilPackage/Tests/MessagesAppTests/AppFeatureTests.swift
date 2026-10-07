import ComposableArchitecture
import MessagesApp
import MessagesDatabase
import OnboardingFeature
import Testing

@MainActor
struct AppFeatureTests {
  @Test
  func launchWithFullDiskAccess() async throws {
    let database = try makeInMemoryChatDatabase()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.chatDatabase = .constant(database)
    }

    await store.send(.task)
    await store.receive(\.accessChecked) {
      $0.hasFullDiskAccess = true
    }
  }

  @Test
  func launchWithoutFullDiskAccessThenGrant() async throws {
    let isGranted = LockIsolated(false)
    let database = try makeInMemoryChatDatabase()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.chatDatabase = ChatDatabase {
        guard isGranted.value else { throw AccessDenied() }
        return database
      }
    }

    await store.send(.task)
    await store.receive(\.accessChecked) {
      $0.hasFullDiskAccess = false
      $0.fullDiskAccess = FullDiskAccessFeature.State()
    }

    isGranted.setValue(true)
    await store.send(\.fullDiskAccess.appBecameActive) {
      $0.fullDiskAccess?.isChecking = true
    }
    await store.receive(\.fullDiskAccess.checkResponse) {
      $0.fullDiskAccess?.isChecking = false
    }
    await store.receive(\.fullDiskAccess.delegate.accessGranted) {
      $0.hasFullDiskAccess = true
      $0.fullDiskAccess = nil
    }
  }
}

private struct AccessDenied: Error {}
