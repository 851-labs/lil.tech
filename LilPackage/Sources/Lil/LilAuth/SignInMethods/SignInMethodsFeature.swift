public import ComposableArchitecture
import Foundation
import LilAPI

/// The account's sign-in methods, in account settings: linking another provider's account (with
/// the same Apple and Google flows as signing in, `ProviderAuthorization`) and unlinking one,
/// never the last. Accounts are
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
    /// The provider flows: Apple's sheet or page, and Google's page.
    public var authorization = ProviderAuthorization.State(owner: "sign-in-methods")
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
      self.methods = methods
      self.linking = linking
      self.unlinking = unlinking
      self.failure = failure
    }

    /// The providers the account can link: those it hasn't, that this app can sign in with.
    public var linkableProviders: [SignInMethod.Provider] {
      guard case .loaded(let methods) = methods else { return [] }
      return SignInMethod.Provider.allCases.filter { provider in
        !methods.contains { $0.provider == provider }
          && (provider != .google || authorization.isGoogleAvailable)
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
    case retryButtonTapped
    case methodsLoaded(Result<[SignInMethod], SignInMethodError>)
    case authorization(ProviderAuthorization.Action)
    case linkFinished(Result<SignInMethod, SignInMethodError>)
    case unlinkButtonTapped(SignInMethod)
    case unlinkFinished(Result<SignInMethod.ID, SignInMethodError>)
    case alert(PresentationAction<Alert>)

    public enum Alert: Equatable {
      case confirmUnlink(SignInMethod.ID)
    }
  }

  enum CancelID { case requests }

  /// Stops everything under way, e.g. when the account signs out while the section stays.
  public static func cancel<Action>() -> Effect<Action> {
    .merge(
      ProviderAuthorization.cancel(owner: "sign-in-methods"), .cancel(id: CancelID.requests))
  }

  @Dependency(\.signInMethods) var signInMethods

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(\.authorization, action: \.authorization) {
      ProviderAuthorization()
    }
    Reduce { state, action in
      switch action {
      case .task:
        return load()

      case .retryButtonTapped:
        state.methods = .loading
        return load()

      case .methodsLoaded(.success(let methods)):
        state.methods = .loaded(methods)
        return .none

      case .methodsLoaded(.failure(let error)):
        // A list already shown stays, e.g. when reloading after a link fails.
        if case .loaded = state.methods { return .none }
        state.methods = .failed(error.message)
        return .none

      case .authorization(.delegate(.started(let provider))):
        state.failure = nil
        state.linking = SignInMethod.Provider(provider)
        return .none

      case .authorization(.delegate(.authorized(let credential))):
        // Linking never sends Apple's name, so it isn't kept.
        state.authorization.forgetName()
        return .run { [signInMethods] send in
          await send(
            .linkFinished(
              await catching { () async throws(SignInMethodError) in
                switch credential {
                case .apple(let credential, let nonce):
                  try await signInMethods.linkApple(credential, nonce)
                case .google(let idToken, let nonce):
                  try await signInMethods.linkGoogle(idToken, nonce)
                }
              }))
        }
        .cancellable(id: CancelID.requests)

      // Only for the provider being linked: a late answer from another page changes nothing.
      case .authorization(.delegate(.canceled(let provider))):
        if state.linking == SignInMethod.Provider(provider) { state.linking = nil }
        return .none

      case .authorization(.delegate(.failed(let provider, let failure))):
        if state.linking == SignInMethod.Provider(provider) { state.linking = nil }
        state.failure = SignInMethodError(failure).message
        return .none

      case .authorization:
        return .none

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
          TextState("Unlink Your \(method.provider.name) Account?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmUnlink(method.id)) {
            TextState("Unlink")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("You won't be able to sign in with it anymore.")
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
        .cancellable(id: CancelID.requests)

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
    .cancellable(id: CancelID.requests)
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

extension SignInMethodError {
  init(_ failure: ProviderAuthorization.AuthorizationFailure) {
    switch failure {
    case .unavailable: self = .unavailable
    case .rejected: self = .rejected
    case .failed(let reason): self = .failed(reason)
    }
  }
}

extension SignInMethod.Provider {
  init(_ provider: ProviderAuthorization.Provider) {
    switch provider {
    case .apple: self = .apple
    case .google: self = .google
    }
  }
}
