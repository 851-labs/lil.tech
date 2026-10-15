import Dependencies
import Foundation
import HealthKitAccess
import HealthPhoneApp
import HealthUpload
import LilAuth
import Testing

struct HealthChangesTests {
  @Test
  func changesUploadOnlyWhileSignedIn() async throws {
    let onChange = LockIsolated<(@Sendable (String) async -> Void)?>(nil)
    let synced = LockIsolated<[String]>([])
    let reader = HealthReader { type, _, _ in
      synced.withValue { $0.append(type.id) }
      return HealthPage(mutations: [], anchor: Data("1".utf8), hasMore: false)
    }
    let session = LockIsolated<AuthSession?>(nil)
    let store = SessionStore(load: { session.value }, save: { session.setValue($0) })
    try await withDependencies {
      $0.healthAuthorization.isAvailable = { true }
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.healthObserver = HealthObserver { types, handler in
        #expect(!types.isEmpty)
        onChange.setValue(handler)
      }
      $0.sessionStore = store
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
      $0.healthReader = reader
      $0.uuid = .incrementing
    } operation: {
      try await withDependencies {
        $0.authSessions = AuthSessions()
        $0.healthBackfill = HealthBackfill(types: [
          HealthBackfillType(id: "HKQuantityTypeIdentifierBodyMass")
        ])
      } operation: {
        await HealthChanges.observe()
        let handler = try #require(onChange.value)

        await handler("HKQuantityTypeIdentifierBodyMass")
        #expect(synced.value.isEmpty)

        @Dependency(\.authSessions) var authSessions
        await authSessions.signedIn(
          AuthSession(
            accessToken: "access", accessTokenExpiresAt: Date(timeIntervalSince1970: 1_760_500_000),
            refreshToken: "refresh",
            refreshTokenExpiresAt: Date(timeIntervalSince1970: 1_770_000_000)))
        // Changes go up once there's a backfill.
        @Dependency(\.healthBackfill) var healthBackfill
        try await healthBackfill.run()
        await handler("HKQuantityTypeIdentifierBodyMass")
        #expect(
          synced.value == ["HKQuantityTypeIdentifierBodyMass", "HKQuantityTypeIdentifierBodyMass"])
      }
    }
  }

  @Test
  func withoutHealthNothingIsObserved() async {
    await withDependencies {
      $0.healthAuthorization.isAvailable = { false }
    } operation: {
      await HealthChanges.observe()
    }
  }
}
