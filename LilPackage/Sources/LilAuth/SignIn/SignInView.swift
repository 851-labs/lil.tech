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
              if store.authorization.appleWebAPI != nil {
                // Apple's colors for its button: black on light, white on dark.
                Button {
                  store.send(.authorization(.appleWebButtonTapped))
                } label: {
                  Label("Sign in with Apple", systemImage: "apple.logo")
                    .font(.body.weight(.medium))
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .frame(maxWidth: .infinity, minHeight: SignInButtonMetrics.height)
                    .background(
                      colorScheme == .dark ? Color.white : Color.black,
                      in: .rect(cornerRadius: SignInButtonMetrics.cornerRadius)
                    )
                    .contentShape(.rect(cornerRadius: SignInButtonMetrics.cornerRadius))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 320)
                .opacity(store.authorization.appleWebRequest == nil ? 1 : 0.5)
                .disabled(store.authorization.appleWebRequest != nil)
              }
            #else
              SignInWithAppleButton(.signIn) { request in
                store.send(.authorization(.appleButtonTapped))
                request.requestedScopes = [.fullName, .email]
                request.nonce = store.authorization.nonceHash
              } onCompletion: { result in
                store.send(
                  .authorization(.appleAuthorizationFinished(Self.credential(from: result))))
              }
              .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
              .frame(maxWidth: 320)
              .frame(height: SignInButtonMetrics.height)
              .clipShape(.rect(cornerRadius: SignInButtonMetrics.cornerRadius))
            #endif

            if store.authorization.isGoogleAvailable {
              GoogleSignInButton { store.send(.authorization(.googleButtonTapped)) }
                .frame(maxWidth: 320)
                .disabled(store.authorization.googleRequest != nil)
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

  /// Apple's answer to the native sheet, as the features take it.
  static func credential(
    from result: Result<ASAuthorization, any Error>
  ) -> Result<AppleCredential, ProviderAuthorization.AppleAuthorizationError> {
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
          authorizationCode: AppleCredential.authorizationCode(credential.authorizationCode),
          givenName: credential.fullName?.givenName,
          familyName: credential.fullName?.familyName))
    case .failure(let error as ASAuthorizationError) where error.code == .canceled:
      return .failure(.canceled)
    case .failure(let error):
      return .failure(.failed(error.localizedDescription))
    }
  }
}
