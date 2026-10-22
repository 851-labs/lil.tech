public import Dependencies
public import Foundation
public import LilAPI
import Security

/// A signed-in session: an access token for API requests and a refresh token for the next one.
public struct AuthSession: Codable, Equatable, Sendable {
  public var accessToken: String
  public var accessTokenExpiresAt: Date
  public var refreshToken: String
  public var refreshTokenExpiresAt: Date

  public init(
    accessToken: String,
    accessTokenExpiresAt: Date,
    refreshToken: String,
    refreshTokenExpiresAt: Date
  ) {
    self.accessToken = accessToken
    self.accessTokenExpiresAt = accessTokenExpiresAt
    self.refreshToken = refreshToken
    self.refreshTokenExpiresAt = refreshTokenExpiresAt
  }

  /// The session in `pair`, with its expiry times moved to this device's clock: the server's
  /// times, shifted by how far the device's clock was from the server's when the access token
  /// was issued (its `iat`). A clock that's off by more than a token's lifetime would otherwise
  /// make every token look expired.
  init(_ pair: Components.Schemas.TokenPair, receivedAt: Date) {
    let issuedAt = Self.issuedAt(pair.accessToken)
    let skew = issuedAt.map { receivedAt.timeIntervalSince($0) } ?? 0
    let local = { (milliseconds: Int) in
      Date(timeIntervalSince1970: Double(milliseconds) / 1000).addingTimeInterval(skew)
    }
    self.init(
      accessToken: pair.accessToken,
      accessTokenExpiresAt: local(pair.accessTokenExpiresAt),
      refreshToken: pair.refreshToken,
      refreshTokenExpiresAt: local(pair.refreshTokenExpiresAt)
    )
  }

  /// When the server issued an access token: its JWT `iat` claim, read without verifying it.
  static func issuedAt(_ accessToken: String) -> Date? {
    let parts = accessToken.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var payload = parts[1].replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    struct Claims: Decodable { let iat: Double }
    guard
      let data = Data(base64Encoded: payload),
      let claims = try? JSONDecoder().decode(Claims.self, from: data)
    else { return nil }
    return Date(timeIntervalSince1970: claims.iat)
  }
}

extension DependencyValues {
  /// Where the session is kept between launches.
  public var sessionStore: SessionStore {
    get { self[SessionStore.self] }
    set { self[SessionStore.self] = newValue }
  }
}

/// Keeps the session between launches: the Keychain, in apps.
public struct SessionStore: Sendable {
  public var load: @Sendable () throws -> AuthSession?
  public var save: @Sendable (AuthSession?) throws -> Void

  public init(
    load: @escaping @Sendable () throws -> AuthSession?,
    save: @escaping @Sendable (AuthSession?) throws -> Void
  ) {
    self.load = load
    self.save = save
  }

  /// A store in memory, for tests and previews.
  public static func inMemory(_ session: AuthSession? = nil) -> Self {
    let stored = LockIsolated(session)
    return Self(load: { stored.value }, save: { stored.setValue($0) })
  }

  public struct KeychainError: Error, Equatable {
    public let status: OSStatus
  }

  /// The Keychain item holding `environment`'s session, readable after the device's first
  /// unlock, so background uploads can use it.
  ///
  /// Each server has its own item (851-2974), so a dev build pointed at staging or a preview
  /// never reads the prod session (whose tokens must not reach a server with synthetic data),
  /// replaces it, or deletes it by signing out. Builds of lil health share one Keychain access
  /// group, Debug and Release alike, and a temporary home doesn't separate them.
  ///
  /// It's the data protection Keychain, which on macOS needs an app with an application
  /// identifier. Sign in with Apple needs a provisioning profile, which gives it one.
  public static func keychain(for environment: APIEnvironment) -> Self {
    keychain(for: environment, items: .live)
  }

  static func keychain(for environment: APIEnvironment, items: KeychainItems) -> Self {
    Self(
      load: {
        let query = keychainQuery(for: environment)
        let (status, item) = items.copyMatching(
          query.merging([
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
          ]) { $1 })
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
          throw KeychainError(status: status)
        }
        return try JSONDecoder().decode(AuthSession.self, from: data)
      },
      save: { session in
        let query = keychainQuery(for: environment)
        guard let session else {
          let status = items.delete(query)
          guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
          }
          return
        }
        // Updated in place, so a failed write keeps the previous session.
        let data = try JSONEncoder().encode(session)
        var status = items.update(query, [kSecValueData: data])
        if status == errSecItemNotFound {
          status = items.add(
            query.merging([
              kSecValueData: data,
              kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { $1 })
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
      }
    )
  }

  /// The attributes that pick `environment`'s item: one service, and an account per server.
  ///
  /// Prod's account is `session`, the one item every build used before 851-2974, so Release
  /// builds (and iPhones, which only use prod) keep finding their session after updating, with
  /// nothing to migrate. Any other server's is `session` and its origin, e.g.
  /// `session https://api.staging.lil.tech`.
  static func keychainQuery(for environment: APIEnvironment) -> [CFString: Any] {
    let account =
      switch environment {
      case .prod: "session"
      case .staging, .preview: "session \(environment.baseURL.absoluteString)"
      }
    return [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "tech.lil.auth",
      kSecAttrAccount: account,
      kSecUseDataProtectionKeychain: true,
    ]
  }
}

/// The Keychain's item functions (`SecItemCopyMatching` and the rest), so tests can use a fake
/// Keychain rather than the real one, which apps share.
struct KeychainItems: Sendable {
  var copyMatching: @Sendable (_ query: [CFString: Any]) -> (OSStatus, CFTypeRef?)
  var add: @Sendable (_ attributes: [CFString: Any]) -> OSStatus
  var update: @Sendable (_ query: [CFString: Any], _ changes: [CFString: Any]) -> OSStatus
  var delete: @Sendable (_ query: [CFString: Any]) -> OSStatus

  static let live = Self(
    copyMatching: { query in
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      return (status, item)
    },
    add: { SecItemAdd($0 as CFDictionary, nil) },
    update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
    delete: { SecItemDelete($0 as CFDictionary) }
  )
}

extension SessionStore: DependencyKey {
  public static let liveValue = Self.keychain(for: .current())
  public static var testValue: Self { .inMemory() }
  public static var previewValue: Self { .inMemory() }
}
