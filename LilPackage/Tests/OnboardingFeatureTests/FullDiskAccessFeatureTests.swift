import ComposableArchitecture
import Foundation
import MessagesDatabase
import OnboardingFeature
import Testing

@MainActor
struct FullDiskAccessFeatureTests {
  @Test
  func checkAgainWhileDenied() async {
    let store = TestStore(initialState: FullDiskAccessFeature.State()) {
      FullDiskAccessFeature()
    } withDependencies: {
      $0.chatDatabase = ChatDatabase { throw AccessDenied() }
    }

    await store.send(.checkAgainButtonTapped) {
      $0.isChecking = true
    }
    await store.receive(\.checkResponse) {
      $0.isChecking = false
    }
  }

  @Test
  func grantedAfterReturningFromSystemSettings() async throws {
    let isGranted = LockIsolated(false)
    let grantedDatabase = try makeInMemoryChatDatabase()
    let store = TestStore(initialState: FullDiskAccessFeature.State()) {
      FullDiskAccessFeature()
    } withDependencies: {
      $0.chatDatabase = ChatDatabase {
        guard isGranted.value else { throw AccessDenied() }
        return grantedDatabase
      }
    }

    await store.send(.appBecameActive) {
      $0.isChecking = true
    }
    await store.receive(\.checkResponse) {
      $0.isChecking = false
    }

    isGranted.setValue(true)
    await store.send(.appBecameActive) {
      $0.isChecking = true
    }
    await store.receive(\.checkResponse) {
      $0.isChecking = false
    }
    await store.receive(\.delegate.accessGranted)
  }

  @Test
  func openSystemSettings() async {
    let openedURL = LockIsolated<URL?>(nil)
    let store = TestStore(initialState: FullDiskAccessFeature.State()) {
      FullDiskAccessFeature()
    } withDependencies: {
      $0.openURL = OpenURLEffect { url in
        openedURL.setValue(url)
        return true
      }
    }

    await store.send(.openSystemSettingsButtonTapped)
    #expect(openedURL.value == .fullDiskAccessSettings)
  }
}

private struct AccessDenied: Error {}
