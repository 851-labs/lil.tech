import AuthenticationServices
public import ComposableArchitecture
public import SwiftUI

/// The sign-in screen: the app's name, the stock Sign in with Apple button, a Google button, and
/// what's happening.
public struct SignInView: View {
  let store: StoreOf<SignInFeature>
  let appName: String
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession

  public init(store: StoreOf<SignInFeature>, appName: String) {
    self.store = store
    self.appName = appName
  }

  public var body: some View {
    VStack(spacing: 24) {
      Spacer()
      Text(appName)
        .font(.largeTitle.bold())
      Text("Sign in to sync your data between your devices.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Spacer()

      // Fixed space for the button and the message, so the screen doesn't shift between states.
      VStack(spacing: 12) {
        VStack(spacing: 12) {
          switch store.status {
          case .signedIn:
            Label("Signed in", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          case .signingIn:
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Signing in")
          case .signedOut, .failed:
            SignInWithAppleButton(.signIn) { request in
              store.send(.appleButtonTapped)
              request.requestedScopes = [.fullName, .email]
              request.nonce = store.nonceHash
            } onCompletion: { result in
              store.send(.appleAuthorizationFinished(Self.credential(from: result)))
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(maxWidth: 320)
            .frame(height: 40)

            Button {
              store.send(.googleButtonTapped)
            } label: {
              Text("Sign in with Google")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.extraLarge)
            .frame(maxWidth: 320)
            .disabled(store.googleRequest != nil)
          }
        }
        .frame(height: 100)
        .task(id: store.googleRequest) {
          guard let request = store.googleRequest else { return }
          store.send(.googleAuthorizationFinished(await authorize(request)))
        }

        Text(failureMessage ?? "")
          .font(.callout)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .frame(minHeight: 40, alignment: .top)
      }
      Spacer().frame(height: 24)
    }
    .padding(32)
    .frame(minWidth: 360, minHeight: 420)
  }

  private var failureMessage: String? {
    guard case .failed(let message) = store.status else { return nil }
    return message
  }

  /// Google's sign-in page in a browser sheet, until it redirects back to the app.
  private func authorize(
    _ request: GoogleAuthorizationRequest
  ) async -> Result<URL, GoogleAuthorizationError> {
    do {
      return .success(
        try await webAuthenticationSession.authenticate(
          using: request.url,
          callback: .customScheme(request.callbackScheme),
          additionalHeaderFields: [:]))
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      return .failure(.canceled)
    } catch {
      return .failure(.failed(error.localizedDescription))
    }
  }

  private static func credential(
    from result: Result<ASAuthorization, any Error>
  ) -> Result<AppleCredential, SignInFeature.AppleAuthorizationError> {
    switch result {
    case .success(let authorization):
      guard
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
        let data = credential.identityToken,
        let token = String(data: data, encoding: .utf8)
      else { return .failure(.failed("Apple didn't return an identity token")) }
      return .success(
        AppleCredential(
          identityToken: token,
          givenName: credential.fullName?.givenName,
          familyName: credential.fullName?.familyName))
    case .failure(let error as ASAuthorizationError) where error.code == .canceled:
      return .failure(.canceled)
    case .failure(let error):
      return .failure(.failed(error.localizedDescription))
    }
  }
}

#Preview("Signed out") {
  SignInView(
    store: Store(initialState: SignInFeature.State()) { SignInFeature() },
    appName: "lil health")
}

#Preview("Signing in") {
  SignInView(
    store: Store(initialState: SignInFeature.State(status: .signingIn)) { SignInFeature() },
    appName: "lil health")
}

#Preview("Failed") {
  SignInView(
    store: Store(initialState: SignInFeature.State(status: .failed(SignInError.rejected.message))) {
      SignInFeature()
    },
    appName: "lil health")
}

#Preview("Signed in") {
  SignInView(
    store: Store(initialState: SignInFeature.State(status: .signedIn)) { SignInFeature() },
    appName: "lil health")
}

#Preview("Google sheet open") {
  // `EmptyReducer`: the view's task would open Google's real sign-in page.
  SignInView(
    store: Store(
      initialState: SignInFeature.State(
        googleRequest: GoogleAuthorizationRequest(
          clientID: "preview.apps.googleusercontent.com", codeVerifier: "verifier",
          nonce: "nonce", state: "state"))
    ) {
      EmptyReducer()
    },
    appName: "lil health")
}
