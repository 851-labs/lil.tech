import ComposableArchitecture
import Foundation
import Testing

@testable import LilAuth

// Synthetic data only (AGENTS.md).
private let apple = SignInMethod(
  id: "idt_apple", provider: .apple, email: "ada@privaterelay.appleid.com")
private let google = SignInMethod(id: "idt_google", provider: .google, email: "ada@example.com")

@MainActor
struct SignInMethodsFeatureTests {
  @Test
  func loadsTheMethodsAndOffersTheOthers() async {
    var initial = SignInMethodsFeature.State()
    initial.isGoogleAvailable = true
    let store = TestStore(initialState: initial) {
      SignInMethodsFeature()
    } withDependencies: {
      $0.signInMethods.list = { () throws(SignInMethodError) in [apple] }
    }

    await store.send(.task)
    await store.receive(\.methodsLoaded.success) {
      $0.methods = .loaded([apple])
    }
    #expect(store.state.linkableProviders == [.google])
    // The only method stays.
    #expect(!store.state.canUnlink)
  }

  @Test
  func googleIsOnlyOfferedWithAClient() {
    var state = SignInMethodsFeature.State(methods: .loaded([apple]))
    state.isGoogleAvailable = false
    #expect(state.linkableProviders.isEmpty)
    state.isGoogleAvailable = true
    state.methods = .loaded([apple, google])
    #expect(state.linkableProviders.isEmpty)
    #expect(state.canUnlink)
  }

  @Test
  func linkingGoogle() async {
    var initial = SignInMethodsFeature.State(methods: .loaded([apple]))
    initial.isGoogleAvailable = true
    let store = TestStore(initialState: initial) {
      SignInMethodsFeature()
    } withDependencies: {
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
      $0.googleOAuth = GoogleOAuth(
        clientID: "123-abc.apps.googleusercontent.com",
        authorize: { _ in .success(googleCallback(state: zeroState)) },
        redeem: { code, _ in
          #expect(code == "4/abc")
          return "google-id-token"
        })
      $0.signInMethods.linkGoogle = { idToken, nonce throws(SignInMethodError) in
        #expect(idToken == "google-id-token")
        #expect(nonce == zeroNonce)
        return google
      }
      $0.signInMethods.list = { () throws(SignInMethodError) in [apple, google] }
    }

    await store.send(.linkGoogleButtonTapped) {
      $0.linking = .google
      $0.googleRequest = zeroGoogleRequest
    }
    await store.receive(\.googleAuthorizationFinished.success) {
      $0.googleRequest = nil
    }
    await store.receive(\.linkFinished.success) {
      $0.linking = nil
      $0.methods = .loaded([apple, google])
    }
    await store.receive(\.methodsLoaded.success)
  }

  @Test
  func anAccountThatSignsInToAnotherUserIsRefused() async {
    var initial = SignInMethodsFeature.State(methods: .loaded([google]))
    initial.nonce = zeroNonce
    initial.linking = .apple
    let store = TestStore(initialState: initial) {
      SignInMethodsFeature()
    } withDependencies: {
      $0.signInMethods.linkApple = { credential, nonce throws(SignInMethodError) in
        #expect(credential.identityToken == "apple-token")
        #expect(nonce == zeroNonce)
        throw .inUse(.apple)
      }
    }

    await store.send(
      .appleAuthorizationFinished(.success(AppleCredential(identityToken: "apple-token")))
    ) {
      $0.nonce = nil
    }
    await store.receive(\.linkFinished.failure) {
      $0.linking = nil
      $0.failure = SignInMethodError.inUse(.apple).message
    }
  }

  @Test
  func cancelingApplesSheetLinksNothing() async {
    let store = TestStore(initialState: SignInMethodsFeature.State(methods: .loaded([google]))) {
      SignInMethodsFeature()
    } withDependencies: {
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(Zeros())
    }

    await store.send(.linkAppleButtonTapped) {
      $0.linking = .apple
      $0.nonce = zeroNonce
    }
    await store.send(.appleAuthorizationFinished(.failure(.canceled))) {
      $0.linking = nil
      $0.nonce = nil
    }
  }

  @Test
  func unlinkingAfterConfirming() async {
    let store = TestStore(
      initialState: SignInMethodsFeature.State(methods: .loaded([apple, google]))
    ) {
      SignInMethodsFeature()
    } withDependencies: {
      $0.signInMethods.unlink = { id throws(SignInMethodError) in #expect(id == "idt_apple") }
      $0.signInMethods.list = { () throws(SignInMethodError) in [google] }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.unlinkButtonTapped(apple))
    #expect(store.state.alert != nil)
    await store.send(.alert(.presented(.confirmUnlink("idt_apple")))) {
      $0.alert = nil
      $0.unlinking = "idt_apple"
    }
    await store.receive(\.unlinkFinished.success) {
      $0.unlinking = nil
      $0.methods = .loaded([google])
    }
    await store.receive(\.methodsLoaded.success)
    #expect(!store.state.canUnlink)
  }

  @Test
  func theLastMethodStays() async {
    let store = TestStore(
      initialState: SignInMethodsFeature.State(methods: .loaded([apple, google]))
    ) {
      SignInMethodsFeature()
    } withDependencies: {
      // Another device unlinked Google meanwhile.
      $0.signInMethods.unlink = { _ throws(SignInMethodError) in throw .lastMethod }
      $0.signInMethods.list = { () throws(SignInMethodError) in [apple] }
    }

    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.unlinkButtonTapped(apple))
    store.exhaustivity = .on
    await store.send(.alert(.presented(.confirmUnlink("idt_apple")))) {
      $0.alert = nil
      $0.unlinking = "idt_apple"
    }
    await store.receive(\.unlinkFinished.failure) {
      $0.unlinking = nil
      $0.failure = "Your only sign-in method can't be removed."
    }
    await store.receive(\.methodsLoaded.success) {
      $0.methods = .loaded([apple])
    }
  }

  @Test
  func aFailedReloadKeepsTheList() async {
    let store = TestStore(initialState: SignInMethodsFeature.State(methods: .loaded([apple]))) {
      SignInMethodsFeature()
    } withDependencies: {
      $0.signInMethods.list = { () throws(SignInMethodError) in throw .unavailable }
    }

    await store.send(.task)
    await store.receive(\.methodsLoaded.failure)
  }

  @Test
  func tryingAgainAfterAFailedLoad() async {
    let store = TestStore(initialState: SignInMethodsFeature.State(methods: .failed("offline"))) {
      SignInMethodsFeature()
    } withDependencies: {
      $0.signInMethods.list = { () throws(SignInMethodError) in [apple] }
    }

    await store.send(.retryButtonTapped) {
      $0.methods = .loading
    }
    await store.receive(\.methodsLoaded.success) {
      $0.methods = .loaded([apple])
    }
  }

  @Test
  func anAnswerWithoutItsRequestEndsTheLink() async {
    let store = TestStore(
      initialState: SignInMethodsFeature.State(methods: .loaded([apple]), linking: .google)
    ) {
      SignInMethodsFeature()
    }

    await store.send(.googleAuthorizationFinished(.success(googleCallback(state: zeroState)))) {
      $0.linking = nil
    }
  }
}
