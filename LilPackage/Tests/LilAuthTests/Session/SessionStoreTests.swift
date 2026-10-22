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
    try SessionStore.keychain(for: .staging, items: keychain.items).save(session(1))
    #expect(try SessionStore.keychain(for: .staging, items: keychain.items).load() == session(1))
  }

  @Test
  func replacesTheSessionInPlace() throws {
    let keychain = FakeKeychain()
    let store = SessionStore.keychain(for: .prod, items: keychain.items)
    try store.save(session(1))
    try store.save(session(2))
    #expect(try store.load() == session(2))
    #expect(keychain.count == 1)
  }

  @Test
  func eachServerHasItsOwnSession() throws {
    let keychain = FakeKeychain()
    let environments: [APIEnvironment] = [.prod, .staging, Self.preview, Self.otherPreview]
    for (index, environment) in environments.enumerated() {
      try SessionStore.keychain(for: environment, items: keychain.items).save(session(index))
    }
    for (index, environment) in environments.enumerated() {
      #expect(
        try SessionStore.keychain(for: environment, items: keychain.items).load()
          == session(index))
    }
    #expect(keychain.count == environments.count)
  }

  @Test
  func signingInToAPreviewLeavesProdsSession() throws {
    let keychain = FakeKeychain()
    let prod = SessionStore.keychain(for: .prod, items: keychain.items)
    let preview = SessionStore.keychain(for: Self.preview, items: keychain.items)
    try prod.save(session(1))
    #expect(try preview.load() == nil)
    try preview.save(session(2))
    #expect(try prod.load() == session(1))
  }

  @Test
  func signingOutOfOneServerLeavesTheOthers() throws {
    let keychain = FakeKeychain()
    let prod = SessionStore.keychain(for: .prod, items: keychain.items)
    let staging = SessionStore.keychain(for: .staging, items: keychain.items)
    let preview = SessionStore.keychain(for: Self.preview, items: keychain.items)
    try prod.save(session(1))
    try staging.save(session(2))
    try preview.save(session(3))

    try preview.save(nil)
    #expect(try preview.load() == nil)
    #expect(try prod.load() == session(1))
    #expect(try staging.load() == session(2))

    try staging.save(nil)
    #expect(try prod.load() == session(1))
  }

  /// A Release build that updates keeps the session the previous release saved.
  @Test
  func prodFindsTheSessionSavedBeforeItemsWereKeyedByServer() throws {
    let keychain = FakeKeychain()
    // Exactly what `SessionStore.keychain` added before 851-2974, for every build.
    keychain.add([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "tech.lil.auth",
      kSecAttrAccount: "session",
      kSecUseDataProtectionKeychain: true,
      kSecValueData: try JSONEncoder().encode(session(1)),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ])
    let prod = SessionStore.keychain(for: .prod, items: keychain.items)
    #expect(try prod.load() == session(1))

    // A refresh replaces it in place, as before.
    try prod.save(session(2))
    #expect(keychain.count == 1)
    #expect(try prod.load() == session(2))
  }

  /// Dev builds never see the item older builds shared, which may hold a real prod session.
  @Test
  func otherServersIgnoreTheSessionSavedBeforeItemsWereKeyedByServer() throws {
    let keychain = FakeKeychain()
    keychain.add([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "tech.lil.auth",
      kSecAttrAccount: "session",
      kSecUseDataProtectionKeychain: true,
      kSecValueData: try JSONEncoder().encode(session(1)),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ])
    for environment in [APIEnvironment.staging, Self.preview] {
      let store = SessionStore.keychain(for: environment, items: keychain.items)
      #expect(try store.load() == nil)
      try store.save(session(2))
      try store.save(nil)
    }
    #expect(try SessionStore.keychain(for: .prod, items: keychain.items).load() == session(1))
  }

  @Test
  func prodKeepsTheItemEveryBuildUsedBefore() {
    let query = SessionStore.keychainQuery(for: .prod)
    #expect(query.count == 4)
    #expect(query[kSecClass] as? String == kSecClassGenericPassword as String)
    #expect(query[kSecAttrService] as? String == "tech.lil.auth")
    #expect(query[kSecAttrAccount] as? String == "session")
    #expect(query[kSecUseDataProtectionKeychain] as? Bool == true)
  }

  @Test
  func otherServersAreKeyedByTheirOrigin() {
    #expect(
      SessionStore.keychainQuery(for: .staging)[kSecAttrAccount] as? String
        == "session https://api.staging.lil.tech")
    // A pasted link's path doesn't make it another server.
    let pasted = APIEnvironment(url: "https://lil-api-api-pr-57-abc.851.workers.dev/v1/status")!
    #expect(
      SessionStore.keychainQuery(for: pasted)[kSecAttrAccount] as? String
        == "session https://lil-api-api-pr-57-abc.851.workers.dev")
  }

  @Test
  func reportsKeychainErrors() {
    let keychain = FakeKeychain()
    keychain.failing = errSecInteractionNotAllowed
    let store = SessionStore.keychain(for: .prod, items: keychain.items)
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
/// matches a query when it has every attribute the query names.
final class FakeKeychain: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [[CFString: Any]] = []
  /// Every call fails with this status, like a locked Keychain.
  var failing: OSStatus? {
    get { lock.withLock { _failing } }
    set { lock.withLock { _failing = newValue } }
  }
  private var _failing: OSStatus?

  var count: Int { lock.withLock { stored.count } }

  /// Keys that steer a search rather than naming an attribute.
  private static var searchKeys: Set<CFString> { [kSecReturnData, kSecMatchLimit] }

  private func matches(_ item: [CFString: Any], _ query: [CFString: Any]) -> Bool {
    query.allSatisfy { key, value in
      Self.searchKeys.contains(key) || (item[key] as? NSObject)?.isEqual(value) == true
    }
  }

  @discardableResult
  func add(_ attributes: [CFString: Any]) -> OSStatus {
    lock.withLock {
      if let _failing { return _failing }
      guard !stored.contains(where: { matches($0, Self.primaryKey(attributes)) }) else {
        return errSecDuplicateItem
      }
      stored.append(attributes)
      return errSecSuccess
    }
  }

  /// What makes a generic password unique.
  private static func primaryKey(_ attributes: [CFString: Any]) -> [CFString: Any] {
    attributes.filter { [kSecClass, kSecAttrService, kSecAttrAccount].contains($0.key) }
  }

  var items: KeychainItems {
    KeychainItems(
      copyMatching: { query in
        self.lock.withLock {
          if let failing = self._failing { return (failing, nil) }
          guard let item = self.stored.first(where: { self.matches($0, query) }) else {
            return (errSecItemNotFound, nil)
          }
          return (errSecSuccess, item[kSecValueData] as CFTypeRef?)
        }
      },
      add: { self.add($0) },
      update: { query, changes in
        self.lock.withLock {
          if let failing = self._failing { return failing }
          let indices = self.stored.indices.filter { self.matches(self.stored[$0], query) }
          guard !indices.isEmpty else { return errSecItemNotFound }
          for index in indices { self.stored[index].merge(changes) { $1 } }
          return errSecSuccess
        }
      },
      delete: { query in
        self.lock.withLock {
          if let failing = self._failing { return failing }
          let before = self.stored.count
          self.stored.removeAll { self.matches($0, query) }
          return self.stored.count == before ? errSecItemNotFound : errSecSuccess
        }
      }
    )
  }
}
