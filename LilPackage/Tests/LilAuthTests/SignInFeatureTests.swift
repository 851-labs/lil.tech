import ComposableArchitecture
import Foundation
import LilAuth
import Testing

@MainActor
struct SignInFeatureTests {
  @Test
  func signingIn() async {
    let store = TestStore(initialState: SignInFeature.State()) {
      SignInFeature()
    } withDependencies: {
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
      $0.auth.signInWithApple = { credential, nonce in
        #expect(credential.identityToken == "apple-token")
        #expect(nonce == zeroNonce)
      }
    }

    await store.send(.appleButtonTapped) {
      $0.nonce = zeroNonce
    }
    // Apple gets the nonce's SHA-256.
    #expect(
      store.state.nonceHash == "60e05bd1b195af2f94112fa7197a5c88289058840ce7c6df9693756bc6250f55")
    await store.send(
      .appleAuthorizationFinished(.success(AppleCredential(identityToken: "apple-token")))
    ) {
      $0.status = .signingIn
    }
    await store.receive(\.signInSucceeded) {
      $0.nonce = nil
      $0.status = .signedIn
    }
    await store.receive(\.delegate.signedIn)
  }

  @Test
  func cancelingApplesSheet() async {
    let store = TestStore(initialState: SignInFeature.State()) {
      SignInFeature()
    } withDependencies: {
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
    }

    await store.send(.appleButtonTapped) {
      $0.nonce = zeroNonce
    }
    await store.send(.appleAuthorizationFinished(.failure(.canceled))) {
      $0.nonce = nil
    }
  }

  @Test
  func appleFailing() async {
    let store = TestStore(initialState: SignInFeature.State()) {
      SignInFeature()
    } withDependencies: {
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
    }

    await store.send(.appleButtonTapped) {
      $0.nonce = zeroNonce
    }
    await store.send(.appleAuthorizationFinished(.failure(.failed("No network")))) {
      $0.nonce = nil
      $0.status = .failed("Signing in didn't work: No network")
    }
  }

  @Test
  func theServerFailingThenTryingAgain() async {
    let attempts = LockIsolated(0)
    let store = TestStore(initialState: SignInFeature.State()) {
      SignInFeature()
    } withDependencies: {
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
      $0.auth.signInWithApple = { _, _ throws(SignInError) in
        attempts.withValue { $0 += 1 }
        if attempts.value == 1 { throw .unavailable }
      }
    }
    let credential = AppleCredential(identityToken: "apple-token")

    await store.send(.appleButtonTapped) {
      $0.nonce = zeroNonce
    }
    await store.send(.appleAuthorizationFinished(.success(credential))) {
      $0.status = .signingIn
    }
    await store.receive(\.signInFailed) {
      $0.nonce = nil
      $0.status = .failed("Signing in isn't available right now. Please try again later.")
    }

    await store.send(.appleButtonTapped) {
      $0.nonce = zeroNonce
    }
    await store.send(.appleAuthorizationFinished(.success(credential))) {
      $0.status = .signingIn
    }
    await store.receive(\.signInSucceeded) {
      $0.nonce = nil
      $0.status = .signedIn
    }
    await store.receive(\.delegate.signedIn)
  }

  @Test
  func anAppleResultWithoutANonceFails() async {
    let store = TestStore(initialState: SignInFeature.State()) {
      SignInFeature()
    }

    await store.send(
      .appleAuthorizationFinished(.success(AppleCredential(identityToken: "apple-token")))
    ) {
      $0.status = .failed("Signing in didn't work. Please try again.")
    }
  }
}

private let zeroNonce = String(repeating: "0", count: 64)

/// Always zero, so nonces are predictable.
private struct Zeros: RandomNumberGenerator {
  mutating func next() -> UInt64 { 0 }
}
