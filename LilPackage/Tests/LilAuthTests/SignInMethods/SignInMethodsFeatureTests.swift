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
    initial.authorization.isGoogleAvailable = true
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
    state.authorization.isGoogleAvailable = false
    #expect(state.linkableProviders.isEmpty)
    state.authorization.isGoogleAvailable = true
    state.methods = .loaded([apple, google])
    #expect(state.linkableProviders.isEmpty)
    #expect(state.canUnlink)
  }

  @Test
  func linkingGoogle() async {
    var initial = SignInMethodsFeature.State(methods: .loaded([apple]))
    initial.authorization.isGoogleAvailable = true
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

    await store.send(.authorization(.googleButtonTapped)) {
      $0.authorization.googleRequest = zeroGoogleRequest
    }
    await store.receive(\.authorization.delegate.started) {
      $0.linking = .google
    }
    await store.receive(\.authorization.googleAuthorizationFinished.success) {
      $0.authorization.googleRequest = nil
    }
    await store.receive(\.authorization.delegate.redeemingGoogle)
    await store.receive(\.authorization.delegate.authorized)
    await store.receive(\.linkFinished.success) {
      $0.linking = nil
      $0.methods = .loaded([apple, google])
    }
    await store.receive(\.methodsLoaded.success)
  }

  @Test
  func anAccountThatSignsInToAnotherUserIsRefused() async {
    var initial = SignInMethodsFeature.State(methods: .loaded([google]))
    initial.authorization.nonce = zeroNonce
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
      .authorization(
        .appleAuthorizationFinished(.success(AppleCredential(identityToken: "apple-token"))))
    ) {
      $0.authorization.nonce = nil
    }
    await store.receive(\.authorization.delegate.authorized)
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

    await store.send(.authorization(.appleButtonTapped)) {
      $0.authorization.nonce = zeroNonce
    }
    await store.receive(\.authorization.delegate.started) {
      $0.linking = .apple
    }
    await store.send(.authorization(.appleAuthorizationFinished(.failure(.canceled)))) {
      $0.authorization.nonce = nil
    }
    await store.receive(\.authorization.delegate.canceled) {
      $0.linking = nil
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

    await store.send(
      .authorization(.googleAuthorizationFinished(.success(googleCallback(state: zeroState)))))
    await store.receive(\.authorization.delegate.canceled) {
      $0.linking = nil
    }
  }

  @Test
  func linkingIsntStartedWithoutAPageToOpen() async {
    var initial = SignInMethodsFeature.State(methods: .loaded([google]))
    // A preview deployment: Apple can't return to it, so its page doesn't open.
    initial.authorization.appleWebAPI = nil
    let store = TestStore(initialState: initial) {
      SignInMethodsFeature()
    }

    await store.send(.authorization(.appleWebButtonTapped))
    #expect(store.state.linking == nil)
  }

  @Test
  func aLateAnswerFromAnotherPageDoesntEndALink() async {
    let store = TestStore(
      initialState: SignInMethodsFeature.State(methods: .loaded([google]), linking: .apple)
    ) {
      SignInMethodsFeature()
    }

    // Google's page answering after it closed, while Apple is being linked.
    await store.send(
      .authorization(.googleAuthorizationFinished(.success(googleCallback(state: zeroState)))))
    await store.receive(\.authorization.delegate.canceled)
    #expect(store.state.linking == .apple)
  }

  @Test
  func linkingForgetsApplesName() async {
    var initial = SignInMethodsFeature.State(methods: .loaded([google]))
    initial.authorization.nonce = zeroNonce
    initial.linking = .apple
    let store = TestStore(initialState: initial) {
      SignInMethodsFeature()
    } withDependencies: {
      $0.signInMethods.linkApple = { _, _ throws(SignInMethodError) in apple }
      $0.signInMethods.list = { () throws(SignInMethodError) in [google, apple] }
    }

    await store.send(
      .authorization(
        .appleAuthorizationFinished(
          .success(AppleCredential(identityToken: "t", givenName: "Ada", familyName: "Lovelace"))))
    ) {
      $0.authorization.nonce = nil
      $0.authorization.givenName = "Ada"
      $0.authorization.familyName = "Lovelace"
    }
    await store.receive(\.authorization.delegate.authorized) {
      $0.authorization.givenName = nil
      $0.authorization.familyName = nil
    }
    await store.receive(\.linkFinished.success) {
      $0.linking = nil
      $0.methods = .loaded([google, apple])
    }
    await store.receive(\.methodsLoaded.success)
  }
}
