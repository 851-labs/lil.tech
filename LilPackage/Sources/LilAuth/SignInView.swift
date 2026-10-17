import AuthenticationServices
public import ComposableArchitecture
public import Foundation
public import SwiftUI

/// The sign-in screen: the app's name, a Sign in with Apple button (the stock one on the iPhone,
/// Apple's web page on the Mac), a Google button, and what's happening, with a link to the privacy
/// policy if there's one.
public struct SignInView: View {
  let store: StoreOf<SignInFeature>
  let appName: String
  let privacyPolicy: URL?
  @Environment(\.colorScheme) private var colorScheme

  public init(store: StoreOf<SignInFeature>, appName: String, privacyPolicy: URL? = nil) {
    self.store = store
    self.appName = appName
    self.privacyPolicy = privacyPolicy
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

      // The buttons keep their space while hidden, so the screen doesn't shift between states.
      VStack(spacing: 12) {
        ZStack {
          VStack(spacing: 12) {
            #if os(macOS)
              // Apple's web page: the native sheet needs an entitlement that Developer ID builds
              // can't have (`docs/DECISIONS.md`).
              if store.appleWebAPI != nil {
                // Apple's colors for its button: black on light, white on dark.
                Button {
                  store.send(.appleWebButtonTapped)
                } label: {
                  Label("Sign in with Apple", systemImage: "apple.logo")
                    .font(.body.weight(.medium))
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                      colorScheme == .dark ? Color.white : Color.black,
                      in: .rect(cornerRadius: 8)
                    )
                    .contentShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 320)
                .opacity(store.appleWebRequest == nil ? 1 : 0.5)
                .disabled(store.appleWebRequest != nil)
              }
            #else
              SignInWithAppleButton(.signIn) { request in
                store.send(.appleButtonTapped)
                request.requestedScopes = [.fullName, .email]
                request.nonce = store.nonceHash
              } onCompletion: { result in
                store.send(.appleAuthorizationFinished(Self.credential(from: result)))
              }
              .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
              .frame(maxWidth: 320)
              .frame(height: 44)
            #endif

            if store.isGoogleAvailable {
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

            if store.isTestAccountAvailable {
              Button("Sign in to a Test Account") {
                store.send(.testAccountButtonTapped)
              }
              .font(.callout)
            }
          }
          .opacity(showsButtons ? 1 : 0)
          .disabled(!showsButtons)
          .accessibilityHidden(!showsButtons)

          switch store.status {
          case .signedIn:
            Label("Signed in", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          case .signingIn:
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Signing in")
          case .signedOut, .failed:
            EmptyView()
          }
        }

        Text(failureMessage ?? "")
          .font(.callout)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .frame(minHeight: 40, alignment: .top)
      }
      if let privacyPolicy {
        Link("Privacy Policy", destination: privacyPolicy)
          .font(.footnote)
      }
      Spacer().frame(height: 24)
    }
    .padding(32)
    .frame(minWidth: 360, minHeight: 420)
  }

  private var showsButtons: Bool {
    switch store.status {
    case .signedOut, .failed: true
    case .signingIn, .signedIn: false
    }
  }

  private var failureMessage: String? {
    guard case .failed(let message) = store.status else { return nil }
    return message
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
          authorizationCode: credential.authorizationCode.flatMap {
            String(data: $0, encoding: .utf8)
          },
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
    appName: "lil health", privacyPolicy: URL(string: "https://lil.tech/privacy"))
}

#Preview("Pointed at a preview deployment") {
  var state = SignInFeature.State()
  state.isTestAccountAvailable = true
  // Apple can't return to a preview: the Mac has no Apple button there.
  state.appleWebAPI = nil
  return SignInView(
    store: Store(initialState: state) { SignInFeature() }, appName: "lil health",
    privacyPolicy: URL(string: "https://lil.tech/privacy"))
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

#Preview("Sign-up unavailable in region") {
  SignInView(
    store: Store(
      initialState: SignInFeature.State(
        status: .failed(SignInError.signUpUnavailableInRegion.message))
    ) {
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
  SignInView(
    store: Store(
      initialState: SignInFeature.State(
        googleRequest: GoogleAuthorizationRequest(
          clientID: "preview.apps.googleusercontent.com", codeVerifier: "verifier",
          nonce: "nonce", state: "state"))
    ) {
      SignInFeature()
    },
    appName: "lil health")
}

#Preview("Apple's page open (the Mac)") {
  var state = SignInFeature.State()
  state.appleWebRequest = AppleWebAuthorizationRequest(
    redirectURI: URL(string: "https://api.lil.tech/v1/auth/apple/web")!, nonce: "nonce",
    state: "state")
  return SignInView(
    store: Store(initialState: state) { SignInFeature() }, appName: "lil health",
    privacyPolicy: URL(string: "https://lil.tech/privacy"))
}
