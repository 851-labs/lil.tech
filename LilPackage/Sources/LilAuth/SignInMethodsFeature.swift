public import ComposableArchitecture
public import Foundation
import LilAPI

/// The account's sign-in methods, in account settings: linking another provider's account (with
/// the same Apple and Google flows as signing in) and unlinking one, never the last. Accounts are
/// never linked by email, or merged (`docs/DECISIONS.md`).
@Reducer
public struct SignInMethodsFeature {
  @ObservableState
  public struct State: Equatable {
    public var methods: Methods
    /// The provider being linked, from its button until the server answers.
    public var linking: SignInMethod.Provider?
    /// The method being unlinked, until the server answers.
    public var unlinking: SignInMethod.ID?
    /// Why the last link or unlink didn't work.
    public var failure: String?
    /// The raw nonce for Apple's sheet, whose SHA-256 (``nonceHash``) Apple gets.
    public var nonce: String?
    /// The Google sign-in in the browser, while it's open.
    public var googleRequest: GoogleAuthorizationRequest?
    /// The Apple sign-in in the browser, while it's open (the Mac).
    public var appleWebRequest: AppleWebAuthorizationRequest?
    /// Whether the app has a Google OAuth client, so Google can be linked.
    public var isGoogleAvailable: Bool
    /// The API Apple's web sign-in returns through, on the Mac (`AppleWebAuthorizationRequest`).
    public var appleWebAPI: URL?
    @Presents public var alert: AlertState<Action.Alert>?

    public enum Methods: Equatable {
      case loading
      case loaded([SignInMethod])
      case failed(String)
    }

    public init(
      methods: Methods = .loading, linking: SignInMethod.Provider? = nil,
      unlinking: SignInMethod.ID? = nil, failure: String? = nil
    ) {
      @Dependency(\.googleOAuth) var googleOAuth
      self.methods = methods
      self.linking = linking
      self.unlinking = unlinking
      self.failure = failure
      self.isGoogleAvailable = googleOAuth.clientID != nil
      self.appleWebAPI = AppleWebAuthorizationRequest.api(for: APIEnvironment.current())
    }

    /// What Apple's request `nonce` is set to.
    public var nonceHash: String? {
      nonce.map(Nonce.sha256Hex)
    }

    /// The providers the account can link: those it hasn't, that this app can sign in with.
    public var linkableProviders: [SignInMethod.Provider] {
      guard case .loaded(let methods) = methods else { return [] }
      return SignInMethod.Provider.allCases.filter { provider in
        !methods.contains { $0.provider == provider }
          && (provider != .google || isGoogleAvailable)
      }
    }

    /// Whether a method can be unlinked: the account keeps at least one.
    public var canUnlink: Bool {
      guard case .loaded(let methods) = methods else { return false }
      return methods.count > 1
    }

    /// Whether a link or unlink is under way, so the buttons wait.
    public var isBusy: Bool {
      linking != nil || unlinking != nil
    }
  }

  public enum Action {
    case task
    case methodsLoaded(Result<[SignInMethod], SignInMethodError>)
    /// The iPhone's Apple button was tapped, just before Apple's sheet appears.
    case linkAppleButtonTapped
    case appleAuthorizationFinished(Result<AppleCredential, SignInFeature.AppleAuthorizationError>)
    /// The Mac's Apple button: Apple's web page, in the browser.
    case linkAppleWebButtonTapped
    case appleWebAuthorizationFinished(Result<URL, SignInFeature.AppleAuthorizationError>)
    case linkGoogleButtonTapped
    case googleAuthorizationFinished(Result<URL, GoogleAuthorizationError>)
    case linkFinished(Result<SignInMethod, SignInMethodError>)
    case unlinkButtonTapped(SignInMethod)
    case unlinkFinished(Result<SignInMethod.ID, SignInMethodError>)
    case alert(PresentationAction<Alert>)

    public enum Alert: Equatable {
      case confirmUnlink(SignInMethod.ID)
    }
  }

  enum CancelID { case google, appleWeb }

  @Dependency(\.appleWebSignIn) var appleWebSignIn
  @Dependency(\.googleOAuth) var googleOAuth
  @Dependency(\.signInMethods) var signInMethods
  @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        return load()

      case .methodsLoaded(.success(let methods)):
        state.methods = .loaded(methods)
        return .none

      case .methodsLoaded(.failure(let error)):
        // A list already shown stays, e.g. when reloading after a link fails.
        if case .loaded = state.methods { return .none }
        state.methods = .failed(error.message)
        return .none

      case .linkAppleButtonTapped:
        state.failure = nil
        state.linking = .apple
        state.nonce = withRandomNumberGenerator { Nonce.randomHex(bytes: 32, using: &$0) }
        return .none

      case .appleAuthorizationFinished(let result):
        return finishApple(result, &state)

      case .linkAppleWebButtonTapped:
        guard let api = state.appleWebAPI else { return .none }
        state.failure = nil
        state.linking = .apple
        let request = withRandomNumberGenerator {
          AppleWebAuthorizationRequest.make(api: api, using: &$0)
        }
        state.nonce = request.nonce
        state.appleWebRequest = request
        return .run { [appleWebSignIn] send in
          await send(.appleWebAuthorizationFinished(await appleWebSignIn.authorize(request)))
        }
        .cancellable(id: CancelID.appleWeb, cancelInFlight: true)

      case .appleWebAuthorizationFinished(let result):
        guard let request = state.appleWebRequest else { return .none }
        state.appleWebRequest = nil
        return finishApple(
          result.flatMap { callback in
            Result { () throws(SignInFeature.AppleAuthorizationError) in
              try request.credential(from: callback)
            }
          },
          &state)

      case .linkGoogleButtonTapped:
        guard let clientID = googleOAuth.clientID else { return .none }
        state.failure = nil
        state.linking = .google
        let request = withRandomNumberGenerator { generator in
          GoogleAuthorizationRequest.make(clientID: clientID, using: &generator)
        }
        state.googleRequest = request
        return .run { [googleOAuth] send in
          await send(.googleAuthorizationFinished(await googleOAuth.authorize(request)))
        }
        .cancellable(id: CancelID.google, cancelInFlight: true)

      case .googleAuthorizationFinished(let result):
        guard let request = state.googleRequest else { return .none }
        state.googleRequest = nil
        let code: String
        do throws(GoogleAuthorizationError) {
          code = try request.code(from: result.get())
        } catch {
          state.linking = nil
          if case .failed(let reason) = error {
            state.failure = SignInMethodError.failed(reason).message
          }
          return .none
        }
        return .run { [googleOAuth, signInMethods] send in
          await send(
            .linkFinished(
              await catching { () async throws(SignInMethodError) in
                let idToken: String
                do {
                  idToken = try await googleOAuth.redeem(code, request)
                } catch {
                  throw .failed(error.localizedDescription)
                }
                return try await signInMethods.linkGoogle(idToken, request.nonce)
              }))
        }

      case .linkFinished(.success(let method)):
        state.linking = nil
        if case .loaded(var methods) = state.methods,
          !methods.contains(where: { $0.id == method.id })
        {
          methods.append(method)
          state.methods = .loaded(methods)
        }
        return load()

      case .linkFinished(.failure(let error)):
        state.linking = nil
        state.failure = error.message
        return .none

      case .unlinkButtonTapped(let method):
        state.alert = AlertState {
          TextState("Unlink \(method.provider.name)?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmUnlink(method.id)) {
            TextState("Unlink")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState(
            "You won't be able to sign in with this \(method.provider.name) account anymore. Devices signed in with it stay signed in."
          )
        }
        return .none

      case .alert(.presented(.confirmUnlink(let id))):
        state.failure = nil
        state.unlinking = id
        return .run { [signInMethods] send in
          await send(
            .unlinkFinished(
              await catching { () async throws(SignInMethodError) in
                try await signInMethods.unlink(id)
                return id
              }))
        }

      case .unlinkFinished(.success(let id)):
        state.unlinking = nil
        if case .loaded(let methods) = state.methods {
          state.methods = .loaded(methods.filter { $0.id != id })
        }
        return load()

      case .unlinkFinished(.failure(let error)):
        state.unlinking = nil
        state.failure = error.message
        return load()

      case .alert:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  private func load() -> Effect<Action> {
    .run { [signInMethods] send in
      await send(
        .methodsLoaded(
          await catching { () async throws(SignInMethodError) in try await signInMethods.list() }))
    }
  }

  /// Links the Apple account from Apple's answer, from the native sheet (the iPhone) or Apple's
  /// web page (the Mac), with the nonce kept for the request.
  private func finishApple(
    _ result: Result<AppleCredential, SignInFeature.AppleAuthorizationError>, _ state: inout State
  ) -> Effect<Action> {
    let nonce = state.nonce
    state.nonce = nil
    switch result {
    case .success(let credential):
      guard let nonce else {
        state.linking = nil
        state.failure = SignInMethodError.rejected.message
        return .none
      }
      return .run { [signInMethods] send in
        await send(
          .linkFinished(
            await catching { () async throws(SignInMethodError) in
              try await signInMethods.linkApple(credential, nonce)
            }))
      }
    case .failure(.canceled):
      state.linking = nil
      return .none
    case .failure(.failed(let reason)):
      state.linking = nil
      state.failure = SignInMethodError.failed(reason).message
      return .none
    }
  }
}

/// What `body` returned or threw.
private func catching<Success>(
  _ body: () async throws(SignInMethodError) -> Success
) async -> Result<Success, SignInMethodError> {
  do {
    return .success(try await body())
  } catch {
    return .failure(error)
  }
}
