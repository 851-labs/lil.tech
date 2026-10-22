import Foundation
import LilAPI
import Security
import Testing

@testable import LilAuth

/// The Keychain session store, against a fake Keychain: the real one is shared with every build
/// of lil health on the Mac, including a Release one that may be signed in to a real account.
struct SessionStoreTests {
  static let preview = APIEnvironment(url: "https://lil-api-api-pr-57-abc.851.workers.dev")!
  static let otherPreview = APIEnvironment(url: "https://lil-api-api-pr-58-abc.851.workers.dev")!

  @Test
  func keepsASessionBetweenLaunches() throws {
    let keychain = FakeKeychain()
    try keychain.store(for: .staging, dev: true).save(session(1))
    #expect(try keychain.store(for: .staging, dev: true).load() == session(1))
  }

  @Test
  func replacesTheSessionInPlace() throws {
    let keychain = FakeKeychain()
    let store = keychain.store(for: .prod)
    try store.save(session(1))
    try store.save(session(2))
    #expect(try store.load() == session(2))
    #expect(keychain.count == 1)
  }

  @Test
  func eachServerHasItsOwnSession() throws {
    let keychain = FakeKeychain()
    let stores = [
      keychain.store(for: .prod),
      keychain.store(for: .prod, dev: true),
      keychain.store(for: .staging, dev: true),
      keychain.store(for: Self.preview, dev: true),
      keychain.store(for: Self.otherPreview, dev: true),
    ]
    for (index, store) in stores.enumerated() { try store.save(session(index)) }
    for (index, store) in stores.enumerated() { #expect(try store.load() == session(index)) }
    #expect(keychain.count == stores.count)
  }

  @Test
  func signingInToAPreviewLeavesTheReleaseAppsSession() throws {
    let keychain = FakeKeychain()
    let release = keychain.store(for: .prod)
    let preview = keychain.store(for: Self.preview, dev: true)
    try release.save(session(1))
    #expect(try preview.load() == nil)
    try preview.save(session(2))
    #expect(try release.load() == session(1))
  }

  @Test
  func signingOutOfOneServerLeavesTheOthers() throws {
    let keychain = FakeKeychain()
    let release = keychain.store(for: .prod)
    let staging = keychain.store(for: .staging, dev: true)
    let preview = keychain.store(for: Self.preview, dev: true)
    try release.save(session(1))
    try staging.save(session(2))
    try preview.save(session(3))

    try preview.save(nil)
    #expect(try preview.load() == nil)
    #expect(try release.load() == session(1))
    #expect(try staging.load() == session(2))

    try staging.save(nil)
    #expect(try release.load() == session(1))
  }

  /// Even pointed at prod, a dev build has a session of its own.
  @Test
  func aDevBuildPointedAtProdLeavesTheReleaseAppsSession() throws {
    let keychain = FakeKeychain()
    let release = keychain.store(for: .prod)
    let dev = keychain.store(for: .prod, dev: true)
    try release.save(session(1))
    #expect(try dev.load() == nil)
    try dev.save(session(2))
    try dev.save(nil)
    #expect(try release.load() == session(1))
  }

  /// A Release build (or an iPhone) that updates keeps the session the previous release saved.
  @Test
  func prodFindsTheSessionSavedBeforeItemsWereKeyedByServer() throws {
    let keychain = FakeKeychain()
    try keychain.addSessionSavedBeforeItemsWereKeyedByServer(session(1))
    let release = keychain.store(for: .prod)
    #expect(try release.load() == session(1))

    // A refresh replaces it in place, as before.
    try release.save(session(2))
    #expect(keychain.count == 1)
    #expect(try release.load() == session(2))
  }

  /// Dev builds never see the item older builds shared, which may hold a real prod session.
  @Test
  func devBuildsIgnoreTheSessionSavedBeforeItemsWereKeyedByServer() throws {
    let keychain = FakeKeychain()
    try keychain.addSessionSavedBeforeItemsWereKeyedByServer(session(1))
    for environment in [APIEnvironment.prod, .staging, Self.preview] {
      let store = keychain.store(for: environment, dev: true)
      #expect(try store.load() == nil)
      try store.save(session(2))
      try store.save(nil)
    }
    #expect(try keychain.store(for: .prod).load() == session(1))
  }

  @Test
  func releaseBuildsKeepTheItemEveryBuildUsedBefore() {
    let query = SessionStore.keychainQuery(for: .prod, allowsOverride: false)
    #expect(query.count == 4)
    #expect(query[kSecClass] as? String == kSecClassGenericPassword as String)
    #expect(query[kSecAttrService] as? String == "tech.lil.auth")
    #expect(query[kSecAttrAccount] as? String == "session")
    #expect(query[kSecUseDataProtectionKeychain] as? Bool == true)
  }

  @Test
  func devBuildsKeyEveryServerByItsOrigin() {
    func account(_ environment: APIEnvironment) -> String? {
      SessionStore.keychainQuery(for: environment, allowsOverride: true)[kSecAttrAccount]
        as? String
    }
    #expect(account(.prod) == "session https://api.lil.tech")
    #expect(account(.staging) == "session https://api.staging.lil.tech")
    #expect(account(Self.preview) == "session https://lil-api-api-pr-57-abc.851.workers.dev")
  }

  /// One server is one item, however its URL is spelled.
  @Test
  func originIgnoresSpelling() {
    let origin = "https://lil-api-api-pr-57-abc.851.workers.dev"
    for spelling in [
      "https://lil-api-api-pr-57-abc.851.workers.dev",
      "https://lil-api-api-pr-57-abc.851.workers.dev/",
      "https://lil-api-api-pr-57-abc.851.workers.dev/v1/status",
      "HTTPS://Lil-API-api-pr-57-abc.851.Workers.dev",
      "https://lil-api-api-pr-57-abc.851.workers.dev:443",
    ] {
      #expect(SessionStore.origin(URL(string: spelling)!) == origin)
    }
    #expect(SessionStore.origin(URL(string: "http://localhost:1337")!) == "http://localhost:1337")
  }

  @Test
  func reportsKeychainErrors() {
    let keychain = FakeKeychain()
    keychain.fail(with: errSecInteractionNotAllowed)
    let store = keychain.store(for: .prod)
    #expect(throws: SessionStore.KeychainError(status: errSecInteractionNotAllowed)) {
      try store.load()
    }
    #expect(throws: SessionStore.KeychainError(status: errSecInteractionNotAllowed)) {
      try store.save(session(1))
    }
    #expect(throws: SessionStore.KeychainError(status: errSecInteractionNotAllowed)) {
      try store.save(nil)
    }
  }
}

/// A Keychain in memory, matching items the way `SecItem` matches generic passwords: an item
/// matches a query when it has every attribute the query names. `kSecUseDataProtectionKeychain`
/// counts as one, as the Keychain it names holds its own items.
///
/// Locked by hand: its items aren't `Sendable`, which `LockIsolated`'s `withValue` needs.
final class FakeKeychain: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [[CFString: Any]] = []
  private var failingStatus: OSStatus?

  var count: Int { lock.withLock { stored.count } }

  /// Makes every call fail with `status`, like a locked Keychain.
  func fail(with status: OSStatus) { lock.withLock { failingStatus = status } }

  /// The store a Release build (`dev: false`) or a dev build uses for `environment`.
  func store(for environment: APIEnvironment, dev: Bool = false) -> SessionStore {
    SessionStore.keychain(for: environment, allowsOverride: dev, items: items)
  }

  /// Adds `session` exactly as `SessionStore.keychain` did before 851-2974, for every build.
  func addSessionSavedBeforeItemsWereKeyedByServer(_ session: AuthSession) throws {
    let status = add([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "tech.lil.auth",
      kSecAttrAccount: "session",
      kSecUseDataProtectionKeychain: true,
      kSecValueData: try JSONEncoder().encode(session),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ])
    #expect(status == errSecSuccess)
  }

  var items: KeychainItems {
    KeychainItems(
      copyMatching: { query in
        self.lock.withLock {
          if let status = self.failingStatus { return (status, nil) }
          guard let item = self.stored.first(where: { Self.matches($0, query) }) else {
            return (errSecItemNotFound, nil)
          }
          return (errSecSuccess, item[kSecValueData] as CFTypeRef?)
        }
      },
      add: { self.add($0) },
      update: { query, changes in
        self.lock.withLock {
          if let status = self.failingStatus { return status }
          let indices = self.stored.indices.filter { Self.matches(self.stored[$0], query) }
          guard !indices.isEmpty else { return errSecItemNotFound }
          for index in indices { self.stored[index].merge(changes) { $1 } }
          return errSecSuccess
        }
      },
      delete: { query in
        self.lock.withLock {
          if let status = self.failingStatus { return status }
          let before = self.stored.count
          self.stored.removeAll { Self.matches($0, query) }
          return self.stored.count == before ? errSecItemNotFound : errSecSuccess
        }
      }
    )
  }

  private func add(_ attributes: [CFString: Any]) -> OSStatus {
    lock.withLock {
      if let status = failingStatus { return status }
      // What makes a generic password unique.
      let key = attributes.filter {
        [kSecClass, kSecAttrService, kSecAttrAccount].contains($0.key)
      }
      guard !stored.contains(where: { Self.matches($0, key) }) else { return errSecDuplicateItem }
      stored.append(attributes)
      return errSecSuccess
    }
  }

  private static func matches(_ item: [CFString: Any], _ query: [CFString: Any]) -> Bool {
    // These steer a search rather than naming an attribute.
    let searchKeys: Set<CFString> = [kSecReturnData, kSecMatchLimit]
    return query.allSatisfy { key, value in
      searchKeys.contains(key) || (item[key] as? NSObject)?.isEqual(value) == true
    }
  }
}
