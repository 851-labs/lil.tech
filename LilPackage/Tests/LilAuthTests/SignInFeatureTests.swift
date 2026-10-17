import ComposableArchitecture
import Foundation
import Testing

@testable import LilAuth

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
  func theServerFailingThenTryingAgainKeepsApplesName() async {
    let attempts = LockIsolated(0)
    let store = TestStore(initialState: SignInFeature.State()) {
      SignInFeature()
    } withDependencies: {
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
      $0.auth.signInWithApple = { credential, _ throws(SignInError) in
        #expect(credential.givenName == "Ada")
        #expect(credential.familyName == "Lovelace")
        attempts.withValue { $0 += 1 }
        if attempts.value == 1 { throw .unavailable }
      }
    }

    await store.send(.appleButtonTapped) {
      $0.nonce = zeroNonce
    }
    await store.send(
      .appleAuthorizationFinished(
        .success(
          AppleCredential(identityToken: "apple-token", givenName: "Ada", familyName: "Lovelace"))
      )
    ) {
      $0.givenName = "Ada"
      $0.familyName = "Lovelace"
      $0.status = .signingIn
    }
    await store.receive(\.signInFailed) {
      $0.nonce = nil
      $0.status = .failed("Signing in isn't available right now. Please try again later.")
    }

    // Apple only gives the name the first time.
    await store.send(.appleButtonTapped) {
      $0.nonce = zeroNonce
      $0.status = .signedOut
    }
    await store.send(
      .appleAuthorizationFinished(.success(AppleCredential(identityToken: "apple-token-2")))
    ) {
      $0.status = .signingIn
    }
    await store.receive(\.signInSucceeded) {
      $0.nonce = nil
      $0.givenName = nil
      $0.familyName = nil
      $0.status = .signedIn
    }
    await store.receive(\.delegate.signedIn)
  }

  @Test
  func signingInWithGoogle() async {
    let store = TestStore(initialState: SignInFeature.State()) {
      SignInFeature()
    } withDependencies: {
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
      $0.googleOAuth = GoogleOAuth(
        clientID: "123-abc.apps.googleusercontent.com",
        authorize: { request in
          #expect(request == zeroGoogleRequest)
          return .success(googleCallback(state: zeroState))
        },
        redeem: { code, request in
          #expect(code == "4/abc")
          #expect(request == zeroGoogleRequest)
          return "google-id-token"
        })
      $0.auth.signInWithGoogle = { idToken, nonce in
        #expect(idToken == "google-id-token")
        #expect(nonce == zeroNonce)
      }
    }

    await store.send(.googleButtonTapped) {
      $0.googleRequest = zeroGoogleRequest
    }
    await store.receive(\.googleAuthorizationFinished.success) {
      $0.googleRequest = nil
      $0.status = .signingIn
    }
    await store.receive(\.signInSucceeded) {
      $0.status = .signedIn
    }
    await store.receive(\.delegate.signedIn)
  }

  @Test
  func googleWithoutAClientIsUnavailable() async {
    let store = TestStore(initialState: SignInFeature.State()) {
      SignInFeature()
    }

    await withKnownIssue {
      await store.send(.googleButtonTapped) {
        $0.status = .failed("Signing in isn't available right now. Please try again later.")
      }
    }
  }

  @Test
  func signingInToTheTestAccount() async {
    let store = TestStore(initialState: SignInFeature.State(status: .failed("Earlier error"))) {
      SignInFeature()
    } withDependencies: {
      $0.auth.signInToTestAccount = { account in #expect(account == "e2e") }
    }

    await store.send(.testAccountButtonTapped) {
      $0.status = .signingIn
    }
    await store.receive(\.signInSucceeded) {
      $0.status = .signedIn
    }
    await store.receive(\.delegate.signedIn)
  }

  @Test
  func aTestAccountIsOnlyOfferedForAPreview() {
    // Tests talk to staging, which has no test accounts.
    #expect(SignInFeature.State().isTestAccountAvailable == false)
  }

  @Test
  func aScriptedRunSignsInToTheTestAccountOnce() async {
    var state = SignInFeature.State()
    state.isTestAccountAvailable = true
    let store = TestStore(initialState: state) {
      SignInFeature()
    } withDependencies: {
      $0.launchSignIn = .once(true)
      $0.auth.signInToTestAccount = { account in #expect(account == "e2e") }
    }

    await store.send(.readyToSignIn) {
      $0.status = .signingIn
    }
    await store.receive(\.signInSucceeded) {
      $0.status = .signedIn
    }
    await store.receive(\.delegate.signedIn)
  }

  @Test
  func theLaunchSignInIsClaimedOnce() {
    let asked = LaunchSignIn.once(true)
    #expect(asked.claim())
    // Signed out later in the same launch: it stays signed out.
    #expect(!asked.claim())
    #expect(!LaunchSignIn.once(false).claim())
  }

  @Test
  func withoutATestAccountTheresNoScriptedSignIn() async {
    let claimed = LockIsolated(false)
    let store = TestStore(initialState: SignInFeature.State()) {
      SignInFeature()
    } withDependencies: {
      $0.launchSignIn = LaunchSignIn {
        claimed.setValue(true)
        return true
      }
    }

    // Staging, in tests: no test account, so the launch's sign-in isn't used up.
    await store.send(.readyToSignIn)
    #expect(!claimed.value)
  }

  @Test
  func closingGooglesSheetAfterAFailure() async {
    let store = TestStore(initialState: SignInFeature.State(status: .failed("Earlier error"))) {
      SignInFeature()
    } withDependencies: {
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
      $0.googleOAuth.clientID = "123-abc.apps.googleusercontent.com"
      $0.googleOAuth.authorize = { _ in .failure(.canceled) }
    }

    // A new try clears the last one's error.
    await store.send(.googleButtonTapped) {
      $0.status = .signedOut
      $0.googleRequest = zeroGoogleRequest
    }
    await store.receive(\.googleAuthorizationFinished.failure) {
      $0.googleRequest = nil
    }
  }

  @Test
  func cancelingGoogle() async {
    let store = TestStore(initialState: SignInFeature.State(googleRequest: zeroGoogleRequest)) {
      SignInFeature()
    }

    await store.send(.googleAuthorizationFinished(.failure(.canceled))) {
      $0.googleRequest = nil
    }
  }

  @Test
  func aGoogleRedirectForAnotherRequestFails() async {
    let store = TestStore(initialState: SignInFeature.State(googleRequest: zeroGoogleRequest)) {
      SignInFeature()
    }

    await store.send(.googleAuthorizationFinished(.success(googleCallback(state: "other")))) {
      $0.googleRequest = nil
      $0.status = .failed("Signing in didn't work: Google's answer didn't match")
    }
  }

  @Test
  func googleFailingToRedeemTheCode() async {
    struct Offline: LocalizedError {
      var errorDescription: String? { "The Internet connection appears to be offline." }
    }
    let store = TestStore(initialState: SignInFeature.State(googleRequest: zeroGoogleRequest)) {
      SignInFeature()
    } withDependencies: {
      $0.googleOAuth.redeem = { _, _ in throw Offline() }
    }

    await store.send(.googleAuthorizationFinished(.success(googleCallback(state: zeroState)))) {
      $0.googleRequest = nil
      $0.status = .signingIn
    }
    await store.receive(\.signInFailed) {
      $0.status = .failed(
        "Signing in didn't work: The Internet connection appears to be offline.")
    }
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
private let zeroState = String(repeating: "0", count: 32)

private let zeroGoogleRequest = GoogleAuthorizationRequest(
  clientID: "123-abc.apps.googleusercontent.com",
  codeVerifier: String(repeating: "A", count: 43),
  nonce: zeroNonce,
  state: zeroState
)

private func googleCallback(state: String) -> URL {
  URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=\(state)&code=4%2Fabc")!
}
