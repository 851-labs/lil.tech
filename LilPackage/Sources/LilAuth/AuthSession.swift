public import Dependencies
public import Foundation
import LilAPI
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

  /// The Keychain, readable after the device's first unlock, so background uploads can use it.
  ///
  /// It's the data protection Keychain, which on macOS needs an app with an application
  /// identifier. Sign in with Apple needs a provisioning profile, which gives it one.
  public static let keychain = Self(
    load: {
      var item: CFTypeRef?
      let status = SecItemCopyMatching(
        keychainQuery.merging([
          kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]) { $1 } as CFDictionary,
        &item
      )
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = item as? Data else {
        throw KeychainError(status: status)
      }
      return try JSONDecoder().decode(AuthSession.self, from: data)
    },
    save: { session in
      guard let session else {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
          throw KeychainError(status: status)
        }
        return
      }
      // Updated in place, so a failed write keeps the previous session.
      let data = try JSONEncoder().encode(session)
      var status = SecItemUpdate(
        keychainQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
      if status == errSecItemNotFound {
        status = SecItemAdd(
          keychainQuery.merging([
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
          ]) { $1 } as CFDictionary,
          nil
        )
      }
      guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
  )

  private static var keychainQuery: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "tech.lil.auth",
      kSecAttrAccount: "session",
      kSecUseDataProtectionKeychain: true,
    ]
  }
}

extension SessionStore: DependencyKey {
  public static let liveValue = Self.keychain
  public static var testValue: Self { .inMemory() }
  public static var previewValue: Self { .inMemory() }
}
