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

  init(_ pair: Components.Schemas.TokenPair) {
    self.init(
      accessToken: pair.accessToken,
      accessTokenExpiresAt: Date(timeIntervalSince1970: Double(pair.accessTokenExpiresAt) / 1000),
      refreshToken: pair.refreshToken,
      refreshTokenExpiresAt: Date(timeIntervalSince1970: Double(pair.refreshTokenExpiresAt) / 1000)
    )
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
      SecItemDelete(keychainQuery as CFDictionary)
      guard let session else { return }
      let status = SecItemAdd(
        keychainQuery.merging([
          kSecValueData: try JSONEncoder().encode(session),
          kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 } as CFDictionary,
        nil
      )
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
