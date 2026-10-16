import ComposableArchitecture
import Foundation
import HealthPhoneApp
import HealthUpload
import Testing

@MainActor
struct HealthConsentFeatureTests {
  @Test
  func aFailedAgreementSaysWhyAndCanBeTriedAgain() async {
    let outdated = LockIsolated(true)
    let store = TestStore(initialState: HealthConsentFeature.State()) {
      HealthConsentFeature()
    } withDependencies: {
      $0.healthConsent.give = {
        if outdated.value { throw HealthConsentClient.Outdated() }
      }
    }

    await store.send(.agreeButtonTapped) {
      $0.isSaving = true
    }
    await store.receive(\.agreeFailed) {
      $0.isSaving = false
      $0.failure = "The privacy policy changed. Update lil health to review it."
    }
    outdated.setValue(false)
    await store.send(.agreeButtonTapped) {
      $0.isSaving = true
      $0.failure = nil
    }
    await store.receive(\.agreed) {
      $0.isSaving = false
    }
    await store.receive(\.delegate.agreed)
  }

  @Test
  func notNow() async {
    let store = TestStore(initialState: HealthConsentFeature.State()) {
      HealthConsentFeature()
    }
    await store.send(.notNowButtonTapped)
    await store.receive(\.delegate.notNow)
  }
}
