import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthAgentAccess
import HealthDatabase
import LilAPI
import LilAuth
import LilSync
import SQLiteData
import Testing

@testable import HealthMacApp

/// Each server's local data on the Mac is its own in a Debug build (851-2977), and signing out of
/// one deletes only its own: the database, agent access and its log, and the cached blobs. The
/// Release app's data, in today's folders, is never touched. All in a temporary folder, with
/// synthetic data.
@Suite(.dependencies)
@MainActor
struct LocalDataPerServerTests {
  /// Where this Mac's folders would be: Application Support and Caches.
  let root: URL
  let preview = APIEnvironment.preview(URL(string: "https://lil-api-api-pr-1-a.851.workers.dev")!)
  let otherPreview = APIEnvironment.preview(
    URL(string: "https://lil-api-api-pr-2-b.851.workers.dev")!)

  init() throws {
    root = URL.temporaryDirectory.appending(
      path: "LocalDataPerServerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  /// One server's (or the Release app's) local data, made the way the app makes it.
  struct ServerData {
    let directory: URL
    let database: any DatabaseWriter
    let access: AgentAccessStore
    let caches: URL
    let blob: URL
    let engine: LilSyncEngine

    init(_ environment: APIEnvironment, allowsOverride: Bool, root: URL) throws {
      directory = HealthDatabase.macDirectory(
        for: environment, allowsOverride: allowsOverride,
        applicationSupport: root.appending(path: "Application Support"))
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let database = try HealthDatabase.make(at: directory.appending(path: "Health.sqlite"))
      self.database = database
      try database.write { db in
        try HealthStatisticsDevice.insert {
          HealthStatisticsDevice(
            id: "dev_1", device: "dev_1", pairedWithWatch: false, reportedAt: 1_760_400_000_000)
        }
        .execute(db)
        try HealthStatistic.insert {
          HealthStatistic(
            id: "dev_1/steps@1760400000000", device: "dev_1",
            type: "HKQuantityTypeIdentifierStepCount", bucketStart: 1_760_400_000_000, sum: 1200,
            unit: "count")
        }
        .execute(db)
      }
      access = AgentAccessStore(directory: directory)
      try access.setEnabled(true, at: Date(timeIntervalSince1970: 1_760_400_000))
      let caches = LilSyncEngine.cachesDirectory(
        for: environment, allowsOverride: allowsOverride,
        caches: root.appending(path: "Caches"), bundleIdentifier: "tech.lil.health")
      self.caches = caches
      let blobs = caches.appending(path: "HealthBlobs")
      try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
      blob = blobs.appending(path: "synthetic")
      try Data("synthetic".utf8).write(to: blob)
      engine = withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(Date(timeIntervalSince1970: 1_760_400_000))
        $0.withRandomNumberGenerator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
      } operation: {
        LilSyncEngine(
          entities: HealthDatabase.syncEntities, syncSchema: HealthDatabase.syncSchema,
          partsDirectory: caches.appending(path: "SnapshotParts"))
      }
    }

    func statistics() throws -> Int {
      try database.read { try HealthStatistic.fetchCount($0) }
    }

    var blobCache: BlobCache {
      BlobCache(
        directory: blob.deletingLastPathComponent(), maxBytes: 1 << 20,
        url: { _ in throw CancellationError() }, download: .testValue)
    }

    var hasBlob: Bool { FileManager.default.fileExists(atPath: blob.path(percentEncoded: false)) }
  }

  @Test
  func eachServerHasItsOwnFolders() throws {
    let release = try ServerData(.prod, allowsOverride: false, root: root)
    let prod = try ServerData(.prod, allowsOverride: true, root: root)
    let staging = try ServerData(.staging, allowsOverride: true, root: root)
    let first = try ServerData(preview, allowsOverride: true, root: root)
    let second = try ServerData(otherPreview, allowsOverride: true, root: root)
    let all = [release, prod, staging, first, second]
    #expect(Set(all.map(\.directory)).count == all.count)
    #expect(Set(all.map(\.caches)).count == all.count)
    #expect(
      staging.directory.path(percentEncoded: false).hasSuffix(
        "Application Support/tech.lil.health/Servers/api.staging.lil.tech/"))
    #expect(
      prod.caches.path(percentEncoded: false).hasSuffix(
        "Caches/tech.lil.health/Servers/api.lil.tech/LilSync/"))
  }

  /// A Debug build signed out of one server, as when it opens without a session there, deletes
  /// that server's data, and leaves another server's and the Release app's.
  @Test(.timeLimit(.minutes(1)))
  func signingOutOfOneServerLeavesTheOthers() async throws {
    let release = try ServerData(.prod, allowsOverride: false, root: root)
    let signingOut = try ServerData(preview, allowsOverride: true, root: root)
    let other = try ServerData(otherPreview, allowsOverride: true, root: root)
    let engine = signingOut.engine
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess = .live(signingOut.access)
      $0.sync = SyncClient(
        run: {}, listen: { _ in }, syncNow: {}, push: { _ in },
        status: { AsyncStream { $0.finish() } },
        removeLocalData: { try await engine.removeLocalData() })
      $0.blobCache = signingOut.blobCache
    }
    store.exhaustivity = .off
    await store.send(.signedInChanged(false))
    await store.receive(\.signIn.readyToSignIn)
    await store.finish()

    // The server signed out of: its data is gone.
    #expect(try signingOut.statistics() == 0)
    #expect(try !signingOut.access.isEnabled())
    #expect(!signingOut.hasBlob)
    // The others' is all there.
    for kept in [other, release] {
      #expect(try kept.statistics() == 1)
      #expect(try kept.access.isEnabled())
      #expect(kept.hasBlob)
    }
  }
}
