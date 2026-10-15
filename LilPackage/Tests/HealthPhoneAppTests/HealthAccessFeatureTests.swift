import ComposableArchitecture
import Foundation
import HealthKitAccess
import HealthPhoneApp
import Testing

@MainActor
struct HealthAccessFeatureTests {
  struct Unavailable: Error {}

  @Test
  func askingThenChoosingMedications() async {
    let asked = LockIsolated<[PerObjectHealthType]>([])
    let store = TestStore(initialState: HealthAccessFeature.State()) {
      HealthAccessFeature()
    } withDependencies: {
      $0.healthAuthorization.requestRead = {}
      $0.healthAuthorization.requestPerObject = { type in asked.withValue { $0.append(type) } }
    }

    await store.send(.continueButtonTapped) {
      $0.step = .requesting
    }
    await store.receive(\.readRequestFinished) {
      $0.step = .perObject
    }
    await store.send(.perObjectButtonTapped(.medications)).finish()
    #expect(asked.value == [.medications])
    await store.send(.doneButtonTapped)
    await store.receive(\.delegate.finished)
  }

  @Test
  func aFailedRequestCanBeTriedAgain() async {
    let store = TestStore(initialState: HealthAccessFeature.State()) {
      HealthAccessFeature()
    } withDependencies: {
      $0.healthAuthorization.requestRead = { throw Unavailable() }
    }

    await store.send(.continueButtonTapped) {
      $0.step = .requesting
    }
    await store.receive(\.requestFailed) {
      $0.step = .explain
      $0.failure = Unavailable().localizedDescription
    }
  }
}
