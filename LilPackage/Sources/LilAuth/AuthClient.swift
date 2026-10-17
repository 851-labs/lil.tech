public import Dependencies
import Foundation
public import LilAPI
import OpenAPIRuntime

#if os(macOS)
  import SystemConfiguration
#endif

/// What Sign in with Apple hands the app.
public struct AppleCredential: Equatable, Sendable {
  public var identityToken: String
  /// Apple only gives the name on the first sign-in.
  public var givenName: String?
  public var familyName: String?

  public init(identityToken: String, givenName: String? = nil, familyName: String? = nil) {
    self.identityToken = identityToken
    self.givenName = givenName
    self.familyName = familyName
  }
}

/// Why signing in didn't work, worded for the sign-in screen.
public enum SignInError: Error, Equatable, Sendable {
  /// The server didn't accept the provider's token. Signing in again usually works.
  case rejected
  /// Signing in isn't available right now; try again later.
  case unavailable
  /// New accounts can't be made from where the user is (mainland China). Existing accounts can
  /// still sign in.
  case signUpUnavailableInRegion
  case failed(String)

  public var message: String {
    switch self {
    case .rejected: "Signing in didn't work. Please try again."
    case .unavailable: "Signing in isn't available right now. Please try again later."
    case .signUpUnavailableInRegion: "New accounts can't be created in your country or region."
    case .failed(let reason): "Signing in didn't work: \(reason)"
    }
  }
}

/// Why deleting the account didn't work, worded for the app.
public enum AccountDeletionError: Error, Equatable, Sendable {
  /// The server couldn't finish; trying again does.
  case unavailable
  /// No network.
  case offline
  /// The session ended (e.g. it expired); the account may still exist.
  case signedOut
  case failed

  public var message: String {
    switch self {
    case .unavailable: "It isn't possible right now. Please try again later."
    case .offline: "You're offline. Please try again when you're connected."
    case .signedOut: "Your session ended. Sign in again, then delete your account."
    case .failed: "Something went wrong. Please try again."
    }
  }
}

/// The installed app, as the server records it on sign-in.
public struct AuthDevice: Equatable, Sendable {
  public var app: String
  public var platform: Components.Schemas.DeviceInfo.PlatformPayload
  public var name: String?

  public init(app: String, platform: Components.Schemas.DeviceInfo.PlatformPayload, name: String?) {
    self.app = app
    self.platform = platform
    self.name = name
  }

  /// This app on this device, named after its bundle ID unless `app` is given.
  public static func current(app: String? = nil) -> Self {
    #if os(iOS)
      Self(app: app ?? Bundle.main.bundleIdentifier ?? "lil", platform: .ios, name: nil)
    #else
      // The computer's name from System Settings, without `Host`'s slow name lookups.
      Self(
        app: app ?? Bundle.main.bundleIdentifier ?? "lil", platform: .macos,
        name: SCDynamicStoreCopyComputerName(nil, nil) as String?)
    #endif
  }
}

extension DependencyValues {
  /// Signing in and out.
  public var auth: AuthClient {
    get { self[AuthClient.self] }
    set { self[AuthClient.self] = newValue }
  }

  /// The device sign-ins are recorded for. Apps set it at launch, e.g. `.current(app: "health-ios")`.
  public var authDevice: AuthDevice {
    get { self[AuthDeviceKey.self] }
    set { self[AuthDeviceKey.self] = newValue }
  }
}

private enum AuthDeviceKey: DependencyKey {
  static var liveValue: AuthDevice { .current() }
  static var testValue: AuthDevice { AuthDevice(app: "test", platform: .macos, name: nil) }
}

/// Signing in and out, as features use it.
public struct AuthClient: Sendable {
  /// Exchanges Sign in with Apple's token for a session. `nonce` is the raw nonce whose SHA-256
  /// the app gave Apple.
  public var signInWithApple:
    @Sendable (_ credential: AppleCredential, _ nonce: String) async throws(SignInError) -> Void
  /// Exchanges Google's ID token for a session. `nonce` is the raw nonce whose SHA-256 the app
  /// gave Google.
  public var signInWithGoogle:
    @Sendable (_ idToken: String, _ nonce: String) async throws(SignInError) -> Void
  public var signOut: @Sendable () async -> Void
  /// Deletes the account and everything uploaded to it, then forgets the session here.
  public var deleteAccount: @Sendable () async throws(AccountDeletionError) -> Void
  /// Whether the app is signed in, now and after every change.
  public var signedInUpdates: @Sendable () async -> AsyncStream<Bool>
  /// Signs in to a synthetic account on a preview deployment, by name, made the first time, so
  /// an iPhone and a Mac can share it (`POST /v1/auth/dev`, which only previews have). For
  /// checking sync end to end with synthetic data, from simulator and Debug Mac builds pointed at
  /// a preview (`APIEnvironment`).
  public var signInToTestAccount: @Sendable (_ account: String) async throws(SignInError) -> Void

  public init(
    signInWithApple:
      @escaping @Sendable (_ credential: AppleCredential, _ nonce: String) async throws(SignInError)
      -> Void,
    signInWithGoogle:
      @escaping @Sendable (_ idToken: String, _ nonce: String) async throws(SignInError) -> Void,
    signOut: @escaping @Sendable () async -> Void,
    deleteAccount: @escaping @Sendable () async throws(AccountDeletionError) -> Void,
    signedInUpdates: @escaping @Sendable () async -> AsyncStream<Bool>,
    signInToTestAccount: @escaping @Sendable (_ account: String) async throws(SignInError) -> Void
  ) {
    self.signInToTestAccount = signInToTestAccount
    self.deleteAccount = deleteAccount
    self.signInWithApple = signInWithApple
    self.signInWithGoogle = signInWithGoogle
    self.signOut = signOut
    self.signedInUpdates = signedInUpdates
  }
}

extension AuthClient: DependencyKey {
  public static var liveValue: Self {
    @Dependency(\.api) var api
    @Dependency(\.authSessions) var sessions
    @Dependency(\.authDevice) var device
    @Dependency(\.date) var date
    /// Calls a sign-in endpoint and starts the session it returns.
    @Sendable func signIn(
      _ call: @Sendable () async throws -> SignInOutcome
    ) async throws(SignInError) {
      let outcome: SignInOutcome
      do {
        outcome = try await call()
      } catch {
        throw .failed(error.localizedDescription)
      }
      switch outcome {
      case .signedIn(let pair):
        guard let pair else { throw .failed("Unexpected response") }
        await sessions.signedIn(AuthSession(pair, receivedAt: date.now))
      case .rejected: throw .rejected
      case .unavailable: throw .unavailable
      case .signUpUnavailableInRegion: throw .signUpUnavailableInRegion
      case .unexpected(let statusCode): throw .failed("HTTP \(statusCode)")
      case .refused(let reason): throw .failed(reason)
      }
    }
    return Self(
      signInWithApple: { credential, nonce throws(SignInError) in
        let request = Components.Schemas.AppleSignInRequest(
          identityToken: credential.identityToken,
          nonce: nonce,
          fullName: .init(givenName: credential.givenName, familyName: credential.familyName),
          device: .init(app: device.app, platform: device.platform, name: device.name)
        )
        try await signIn {
          switch try await api.authApple(body: .json(request)) {
          case .ok(let ok): .signedIn(try? ok.body.json)
          case .unauthorized: .rejected
          case .serviceUnavailable, .tooManyRequests: .unavailable
          case .unavailableForLegalReasons: .signUpUnavailableInRegion
          case .undocumented(let statusCode, _): .unexpected(statusCode)
          }
        }
      },
      signInWithGoogle: { idToken, nonce throws(SignInError) in
        let request = Components.Schemas.GoogleSignInRequest(
          idToken: idToken,
          nonce: nonce,
          device: .init(app: device.app, platform: device.platform, name: device.name)
        )
        try await signIn {
          switch try await api.authGoogle(body: .json(request)) {
          case .ok(let ok): .signedIn(try? ok.body.json)
          case .unauthorized: .rejected
          case .serviceUnavailable, .tooManyRequests: .unavailable
          case .unavailableForLegalReasons: .signUpUnavailableInRegion
          case .undocumented(let statusCode, _): .unexpected(statusCode)
          }
        }
      },
      signOut: { await sessions.signOut() },
      deleteAccount: { () throws(AccountDeletionError) in
        let output: Operations.DeleteMe.Output
        do {
          output = try await api.deleteMe()
        } catch {
          // A timeout or any other network failure isn't the device being offline. The error can
          // be wrapped twice, when refreshing the token failed.
          if isOfflineError(error) { throw .offline }
          var underlying: any Error = error
          while let wrapped = underlying as? ClientError { underlying = wrapped.underlyingError }
          guard let urlError = underlying as? URLError, urlError.code != .cancelled else {
            throw .failed
          }
          throw .unavailable
        }
        switch output {
        case .noContent:
          await sessions.forget()
        case .unauthorized:
          // Not proof the account is gone: the session may just have ended. If the refresh
          // token was rejected too, the app has signed out already.
          throw .signedOut
        case .serviceUnavailable, .tooManyRequests:
          throw .unavailable
        case .undocumented(let statusCode, _):
          throw statusCode >= 500 ? .unavailable : .failed
        }
      },
      signedInUpdates: { await sessions.signedInUpdates() },
      signInToTestAccount: { account throws(SignInError) in
        guard case .preview(let base) = APIEnvironment.current() else { throw .unavailable }
        try await signIn {
          var request = URLRequest(url: base.appending(path: "v1/auth/dev"))
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.httpBody = try JSONEncoder().encode([
            "account": account, "app": device.app, "platform": device.platform.rawValue,
          ])
          let (data, response) = try await URLSession.shared.data(for: request)
          switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
          case 200:
            return .signedIn(
              try? JSONDecoder().decode(Components.Schemas.TokenPair.self, from: data))
          case let status:
            // The server's reason, e.g. that the stage has too many users.
            let reason = try? JSONDecoder().decode([String: String].self, from: data)["message"]
            return .refused(reason ?? "HTTP \(status)")
          }
        }
      }
    )
  }

  public static let previewValue = Self(
    signInWithApple: { _, _ throws(SignInError) in },
    signInWithGoogle: { _, _ throws(SignInError) in },
    signOut: {},
    deleteAccount: { () throws(AccountDeletionError) in },
    signedInUpdates: { AsyncStream { $0.yield(false) } },
    signInToTestAccount: { _ throws(SignInError) in }
  )

  public static var testValue: Self {
    Self(
      signInWithApple: { _, _ throws(SignInError) in
        reportIssue("Unimplemented: @Dependency(\\.auth).signInWithApple")
      },
      signInWithGoogle: { _, _ throws(SignInError) in
        reportIssue("Unimplemented: @Dependency(\\.auth).signInWithGoogle")
      },
      signOut: { reportIssue("Unimplemented: @Dependency(\\.auth).signOut") },
      deleteAccount: { () throws(AccountDeletionError) in
        reportIssue("Unimplemented: @Dependency(\\.auth).deleteAccount")
      },
      signedInUpdates: {
        reportIssue("Unimplemented: @Dependency(\\.auth).signedInUpdates")
        return AsyncStream { $0.finish() }
      },
      signInToTestAccount: { _ throws(SignInError) in
        reportIssue("Unimplemented: @Dependency(\\.auth).signInToTestAccount")
      }
    )
  }
}

/// How a sign-in endpoint answered.
private enum SignInOutcome {
  case signedIn(Components.Schemas.TokenPair?)
  case rejected
  case unavailable
  case signUpUnavailableInRegion
  case unexpected(Int)
  /// Refused, with the server's reason.
  case refused(String)
}
