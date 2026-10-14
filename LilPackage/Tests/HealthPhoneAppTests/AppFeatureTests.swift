import ComposableArchitecture
import HealthPhoneApp
import LilAuth
import Testing

@MainActor
struct AppFeatureTests {
  @Test
  func followsTheSession() async {
    let (updates, continuation) = AsyncStream<Bool>.makeStream()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.auth.signedInUpdates = { updates }
    }

    let task = await store.send(.task)
    continuation.yield(false)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = false
    }
    continuation.yield(true)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = true
    }
    await task.cancel()
  }

  @Test
  func signingOutStartsSignInAfresh() async {
    let signedOut = LockIsolated(false)
    var state = AppFeature.State(isSignedIn: true)
    state.signIn.status = .signedIn
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.auth.signOut = { signedOut.setValue(true) }
    }

    await store.send(.signOutButtonTapped).finish()
    #expect(signedOut.value)
    await store.send(.signedInChanged(false)) {
      $0.isSignedIn = false
      $0.signIn = SignInFeature.State()
    }
  }
}
