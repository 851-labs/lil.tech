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

    await store.send(.authorization(.appleButtonTapped)) {
      $0.authorization.nonce = zeroNonce
    }
    await store.receive(\.authorization.delegate.started)
    // Apple gets the nonce's SHA-256.
    #expect(
      store.state.authorization.nonceHash
        == "60e05bd1b195af2f94112fa7197a5c88289058840ce7c6df9693756bc6250f55")
    await store.send(
      .authorization(
        .appleAuthorizationFinished(.success(AppleCredential(identityToken: "apple-token"))))
    ) {
      $0.authorization.nonce = nil
    }
    await store.receive(\.authorization.delegate.authorized) {
      $0.status = .signingIn
    }
    await store.receive(\.signInSucceeded) {
      $0.status = .signedIn
    }
    await store.receive(\.delegate.signedIn)
  }

  #if os(macOS)
    @Test
    func signingInThroughApplesWebPageOnTheMac() async throws {
      let api = URL(string: "https://api.lil.tech")!
      var initial = SignInFeature.State()
      initial.authorization.appleWebAPI = api
      var zeros = Zeros()
      let request = AppleWebAuthorizationRequest.make(api: api, using: &zeros)
      // Apple's page, for the Services ID, returning through the API.
      let page = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
      let query = Dictionary(
        uniqueKeysWithValues: (page.queryItems ?? []).map { ($0.name, $0.value) })
      #expect(page.host == "appleid.apple.com")
      #expect(query["client_id"] == "tech.lil.health.web")
      #expect(query["redirect_uri"] == "https://api.lil.tech/v1/auth/apple/web")
      #expect(query["response_mode"] == "form_post")
      #expect(query["nonce"] == Nonce.sha256Hex(zeroNonce))
      let store = TestStore(initialState: initial) {
        SignInFeature()
      } withDependencies: {
        $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
        $0.appleWebSignIn = AppleWebSignIn { request in
          // As the API redirects: form-encoded, spaces as "+".
          let user = #"{"name":{"firstName":"Mary Ann","lastName":"van der Berg"}}"#
            .addingPercentEncoding(
              withAllowedCharacters: .alphanumerics.union(.init(charactersIn: " ")))!
            .replacingOccurrences(of: " ", with: "+")
          return .success(
            URL(
              string:
                "tech.lil.health://apple-signin/?id_token=apple-token&code=c0de&state=\(request.state)&user=\(user)"
            )!)
        }
        $0.auth.signInWithApple = { credential, nonce in
          #expect(
            credential
              == AppleCredential(
                identityToken: "apple-token", authorizationCode: "c0de", givenName: "Mary Ann",
                familyName: "van der Berg"))
          #expect(nonce == zeroNonce)
        }
      }

      await store.send(.authorization(.appleWebButtonTapped)) {
        $0.authorization.nonce = zeroNonce
        $0.authorization.appleWebRequest = request
      }
      await store.receive(\.authorization.delegate.started)
      await store.receive(\.authorization.appleWebAuthorizationFinished) {
        $0.authorization.appleWebRequest = nil
        $0.authorization.nonce = nil
        $0.authorization.givenName = "Mary Ann"
        $0.authorization.familyName = "van der Berg"
      }
      await store.receive(\.authorization.delegate.authorized) {
        $0.status = .signingIn
      }
      await store.receive(\.signInSucceeded) {
        $0.authorization.givenName = nil
        $0.authorization.familyName = nil
        $0.status = .signedIn
      }
      await store.receive(\.delegate.signedIn)
    }

    @Test
    func applesWebAnswerWithoutACodeStillSignsIn() throws {
      var generator = Zeros()
      let request = AppleWebAuthorizationRequest.make(
        api: URL(string: "https://api.lil.tech")!, using: &generator)
      for query in ["", "&code="] {
        let callback = URL(
          string: "tech.lil.health://apple-signin/?id_token=t\(query)&state=\(request.state)")!
        #expect(try request.credential(from: callback) == AppleCredential(identityToken: "t"))
      }
    }

    @Test
    func applesWebPageCanceledOrMismatched() async {
      var initial = SignInFeature.State()
      initial.authorization.appleWebAPI = URL(string: "https://api.lil.tech")!
      let answer = LockIsolated<
        @Sendable (AppleWebAuthorizationRequest) -> Result<
          URL, ProviderAuthorization.AppleAuthorizationError
        >
      >({ _ in .failure(.canceled) })
      let store = TestStore(initialState: initial) {
        SignInFeature()
      } withDependencies: {
        $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
        $0.appleWebSignIn = AppleWebSignIn { request in answer.value(request) }
      }
      store.exhaustivity = .off

      // Closed: nothing happens.
      await store.send(.authorization(.appleWebButtonTapped))
      await store.receive(\.authorization.delegate.started)
      await store.receive(\.authorization.delegate.canceled)
      #expect(store.state.status == .signedOut)
      #expect(store.state.authorization.nonce == nil)
      #expect(store.state.authorization.appleWebRequest == nil)

      // An answer to another request: refused.
      answer.setValue { _ in
        .success(URL(string: "tech.lil.health://apple-signin/?id_token=t&state=other")!)
      }
      await store.send(.authorization(.appleWebButtonTapped))
      await store.receive(\.authorization.delegate.started)
      await store.receive(\.authorization.delegate.failed)
      #expect(
        store.state.status == .failed(SignInError.failed("Apple's answer didn't match").message))

      // Cancelled on Apple's page, which the API passes on as an error.
      answer.setValue { request in
        .success(
          URL(
            string:
              "tech.lil.health://apple-signin/?error=user_cancelled_authorize&state=\(request.state)"
          )!)
      }
      await store.send(.authorization(.appleWebButtonTapped))
      await store.receive(\.authorization.delegate.started)
      await store.receive(\.authorization.delegate.canceled)
      #expect(store.state.status == .signedOut)
    }
  #endif

  @Test
  func cancelingApplesSheet() async {
    let store = TestStore(initialState: SignInFeature.State()) {
      SignInFeature()
    } withDependencies: {
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
    }

    await store.send(.authorization(.appleButtonTapped)) {
      $0.authorization.nonce = zeroNonce
    }
    await store.receive(\.authorization.delegate.started)
    await store.send(.authorization(.appleAuthorizationFinished(.failure(.canceled)))) {
      $0.authorization.nonce = nil
    }
    await store.receive(\.authorization.delegate.canceled)
  }

  @Test
  func appleFailing() async {
    let store = TestStore(initialState: SignInFeature.State()) {
      SignInFeature()
    } withDependencies: {
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
    }

    await store.send(.authorization(.appleButtonTapped)) {
      $0.authorization.nonce = zeroNonce
    }
    await store.receive(\.authorization.delegate.started)
    await store.send(.authorization(.appleAuthorizationFinished(.failure(.failed("No network"))))) {
      $0.authorization.nonce = nil
    }
    await store.receive(\.authorization.delegate.failed) {
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

    await store.send(.authorization(.appleButtonTapped)) {
      $0.authorization.nonce = zeroNonce
    }
    await store.receive(\.authorization.delegate.started)
    await store.send(
      .authorization(
        .appleAuthorizationFinished(
          .success(
            AppleCredential(
              identityToken: "apple-token", givenName: "Ada", familyName: "Lovelace"))))
    ) {
      $0.authorization.nonce = nil
      $0.authorization.givenName = "Ada"
      $0.authorization.familyName = "Lovelace"
    }
    await store.receive(\.authorization.delegate.authorized) {
      $0.status = .signingIn
    }
    await store.receive(\.signInFailed) {
      $0.status = .failed("Signing in isn't available right now. Please try again later.")
    }

    // Apple only gives the name the first time.
    await store.send(.authorization(.appleButtonTapped)) {
      $0.authorization.nonce = zeroNonce
    }
    await store.receive(\.authorization.delegate.started) {
      $0.status = .signedOut
    }
    await store.send(
      .authorization(
        .appleAuthorizationFinished(.success(AppleCredential(identityToken: "apple-token-2"))))
    ) {
      $0.authorization.nonce = nil
    }
    await store.receive(\.authorization.delegate.authorized) {
      $0.status = .signingIn
    }
    await store.receive(\.signInSucceeded) {
      $0.authorization.givenName = nil
      $0.authorization.familyName = nil
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

    await store.send(.authorization(.googleButtonTapped)) {
      $0.authorization.googleRequest = zeroGoogleRequest
    }
    await store.receive(\.authorization.delegate.started)
    await store.receive(\.authorization.googleAuthorizationFinished.success) {
      $0.authorization.googleRequest = nil
    }
    await store.receive(\.authorization.delegate.redeemingGoogle) {
      $0.status = .signingIn
    }
    await store.receive(\.authorization.delegate.authorized)
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
      await store.send(.authorization(.googleButtonTapped))
    }
    await store.receive(\.authorization.delegate.failed) {
      $0.status = .failed("Signing in isn't available right now. Please try again later.")
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
    await store.receive(\.authorization.close)
    await store.receive(\.signInSucceeded) {
      $0.status = .signedIn
    }
    await store.receive(\.delegate.signedIn)
  }

  @Test
  func theTestAccountClosesAGooglePageStillOpen() async {
    var initial = SignInFeature.State()
    initial.authorization.googleRequest = zeroGoogleRequest
    let store = TestStore(initialState: initial) {
      SignInFeature()
    } withDependencies: {
      $0.auth.signInToTestAccount = { _ in }
    }

    await store.send(.testAccountButtonTapped) {
      $0.status = .signingIn
    }
    await store.receive(\.authorization.close) {
      $0.authorization.googleRequest = nil
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
    await store.receive(\.authorization.close)
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
    await store.send(.authorization(.googleButtonTapped)) {
      $0.authorization.googleRequest = zeroGoogleRequest
    }
    await store.receive(\.authorization.delegate.started) {
      $0.status = .signedOut
    }
    await store.receive(\.authorization.googleAuthorizationFinished.failure) {
      $0.authorization.googleRequest = nil
    }
    await store.receive(\.authorization.delegate.canceled)
  }

  @Test
  func cancelingGoogle() async {
    var initial = SignInFeature.State()
    initial.authorization.googleRequest = zeroGoogleRequest
    let store = TestStore(initialState: initial) {
      SignInFeature()
    }

    await store.send(.authorization(.googleAuthorizationFinished(.failure(.canceled)))) {
      $0.authorization.googleRequest = nil
    }
    await store.receive(\.authorization.delegate.canceled)
  }

  @Test
  func aGoogleRedirectForAnotherRequestFails() async {
    var initial = SignInFeature.State()
    initial.authorization.googleRequest = zeroGoogleRequest
    let store = TestStore(initialState: initial) {
      SignInFeature()
    }

    await store.send(
      .authorization(.googleAuthorizationFinished(.success(googleCallback(state: "other"))))
    ) {
      $0.authorization.googleRequest = nil
    }
    await store.receive(\.authorization.delegate.failed) {
      $0.status = .failed("Signing in didn't work: Google's answer didn't match")
    }
  }

  @Test
  func googleFailingToRedeemTheCode() async {
    struct Offline: LocalizedError {
      var errorDescription: String? { "The Internet connection appears to be offline." }
    }
    var initial = SignInFeature.State()
    initial.authorization.googleRequest = zeroGoogleRequest
    let store = TestStore(initialState: initial) {
      SignInFeature()
    } withDependencies: {
      $0.googleOAuth.redeem = { _, _ in throw Offline() }
    }

    await store.send(
      .authorization(.googleAuthorizationFinished(.success(googleCallback(state: zeroState))))
    ) {
      $0.authorization.googleRequest = nil
    }
    await store.receive(\.authorization.delegate.redeemingGoogle) {
      $0.status = .signingIn
    }
    await store.receive(\.authorization.delegate.failed) {
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
      .authorization(
        .appleAuthorizationFinished(.success(AppleCredential(identityToken: "apple-token"))))
    )
    await store.receive(\.authorization.delegate.failed) {
      $0.status = .failed("Signing in didn't work. Please try again.")
    }
  }
}

let zeroNonce = String(repeating: "0", count: 64)
let zeroState = String(repeating: "0", count: 32)

let zeroGoogleRequest = GoogleAuthorizationRequest(
  clientID: "123-abc.apps.googleusercontent.com",
  codeVerifier: String(repeating: "A", count: 43),
  nonce: zeroNonce,
  state: zeroState
)

func googleCallback(state: String) -> URL {
  URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=\(state)&code=4%2Fabc")!
}
