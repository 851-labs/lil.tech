import Dependencies
import Foundation
import HTTPTypes
import HealthDatabase
import LilAPI
import LilSync
import OpenAPIRuntime
import SQLiteData
import Testing

/// The stage and token `SyncBootstrapBenchmark` runs against, from the environment.
private struct BenchmarkConfiguration {
  let url: URL
  let token: String
  let result: URL

  static var current: Self? {
    let environment = ProcessInfo.processInfo.environment
    guard
      let url = environment["LIL_BENCH_SYNC_URL"].flatMap(URL.init(string:)),
      let token = environment["LIL_BENCH_SYNC_TOKEN"],
      let result = environment["LIL_BENCH_SYNC_RESULT"]
    else { return nil }
    return Self(url: url, token: token, result: URL(filePath: result))
  }
}

/// The Mac's bootstrap against a real stage, for the sync throughput benchmark (851-2650):
/// `LilSyncEngine.bootstrap()` with the Mac's health entities, into a new database on disk, timing
/// the snapshot's downloads apart from loading them. `scripts/bench-sync` runs it once the
/// stage's snapshot is ready, in Release, with:
///
/// - `LIL_BENCH_SYNC_URL`: the stage, never prod.
/// - `LIL_BENCH_SYNC_TOKEN`: an access token of the benchmark's synthetic user.
/// - `LIL_BENCH_SYNC_RESULT`: where to write the timings, as JSON.
@Suite(.enabled(if: BenchmarkConfiguration.current != nil))
struct SyncBootstrapBenchmark {
  struct Result: Encodable {
    /// Seconds from the start of the bootstrap until the last part was downloaded.
    let downloadSeconds: Double
    /// Seconds from then until the bootstrap finished: loading every part into the tables.
    let insertSeconds: Double
    let totalSeconds: Double
    let parts: Int
    /// Compressed bytes downloaded.
    let bytes: Int
    /// Rows in the synced tables afterwards.
    let records: Int
  }

  /// When downloads ran, and how much they fetched.
  actor Downloads {
    private(set) var parts = 0
    private(set) var bytes = 0
    private(set) var lastFinished: ContinuousClock.Instant?

    func finished(bytes: Int) {
      parts += 1
      self.bytes += bytes
      lastFinished = .now
    }
  }

  @Test
  func bootstrap() async throws {
    let configuration = try #require(BenchmarkConfiguration.current)
    try #require(
      APIEnvironment(url: configuration.url.absoluteString) != .prod,
      "The benchmark never runs against prod")
    let directory = URL.temporaryDirectory.appending(
      path: "lil-bench-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try HealthDatabase.make(at: directory.appending(path: "health.sqlite"))

    let downloads = Downloads()
    let live = SnapshotDownloader.liveValue
    let downloader = SnapshotDownloader { url in
      let data = try await live.download(url)
      await downloads.finished(bytes: data.count)
      return data
    }
    let engine = withDependencies {
      $0.defaultDatabase = database
      $0.api = Client.mock { request, body in
        try await Self.send(request, body: body, to: configuration)
      }
      $0.snapshotDownloader = downloader
      $0.continuousClock = ContinuousClock()
      $0.date = .init { Date() }
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
    } operation: {
      LilSyncEngine(
        entities: HealthDatabase.syncEntities, syncSchema: HealthDatabase.syncSchema,
        partsDirectory: directory.appending(path: "parts", directoryHint: .isDirectory))
    }

    let start = ContinuousClock.now
    try await engine.bootstrap()
    let end = ContinuousClock.now
    let downloaded = await downloads.lastFinished ?? start
    let records = try await database.read { db in
      try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'health%'"
      )
      .reduce(0) { total, table in
        total + (try Int.fetchOne(db, sql: "SELECT count(*) FROM \"\(table)\"") ?? 0)
      }
    }
    let result = Result(
      downloadSeconds: Self.seconds(downloaded - start),
      insertSeconds: Self.seconds(end - downloaded),
      totalSeconds: Self.seconds(end - start),
      parts: await downloads.parts, bytes: await downloads.bytes, records: records)
    try JSONEncoder().encode(result).write(to: configuration.result)
  }

  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

  /// Sends an API request to the stage with the token, over `URLSession` as the app's client does.
  private static func send(
    _ request: HTTPRequest, body: HTTPBody?, to configuration: BenchmarkConfiguration
  ) async throws -> (HTTPResponse, HTTPBody?) {
    guard let url = URL(string: request.path ?? "/", relativeTo: configuration.url) else {
      throw URLError(.badURL)
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method.rawValue
    for field in request.headerFields {
      urlRequest.addValue(field.value, forHTTPHeaderField: field.name.rawName)
    }
    urlRequest.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
    if let body { urlRequest.httpBody = try await Data(collecting: body, upTo: 16 * 1024 * 1024) }
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var fields = HTTPFields()
    for case (let name as String, let value as String) in http.allHeaderFields {
      if let name = HTTPField.Name(name) { fields.append(HTTPField(name: name, value: value)) }
    }
    return (
      HTTPResponse(status: .init(code: http.statusCode), headerFields: fields), HTTPBody(data)
    )
  }
}
