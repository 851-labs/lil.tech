import Foundation
import HealthAgentAccess
import MCP
import Synchronization
import Testing

@testable import HealthCLI

// The route tools on the Mac (851-4164): their answers are the conformance cases'
// (`HealthToolkitConformanceTests`); these check how `lil-health` gets a route's points, from the
// app's blob cache or by asking the app to download them, and the commands' text. Synthetic data
// only: the conformance dataset's routes.

/// 18 October's run, whose route is 0c0f…173.
private let run = "0c0f0000-0000-4000-8000-000000000013"

/// The blobs of the conformance dataset, by SHA-256.
private func datasetBlobs() throws -> [String: Data] {
  let folder = FileManager.default.temporaryDirectory.appending(path: "Blobs-\(UUID().uuidString)")
  try Conformance.writeBlobs(into: folder)
  return Dictionary(
    uniqueKeysWithValues: try FileManager.default.contentsOfDirectory(atPath: folder.path).map {
      ($0, try Data(contentsOf: folder.appending(path: $0)))
    })
}

/// lil health, as the route tools see it: running, and answering a blob's download by putting it
/// in its cache, unless it has none to give.
private final class BlobApp: Sendable {
  let folder: AppFolder
  let cache: URL
  let blobs: [String: Data]
  let asked = Mutex<[AgentAction]>([])

  init(_ folder: AppFolder, cache: URL, blobs: [String: Data]) {
    self.folder = folder
    self.cache = cache
    self.blobs = blobs
  }

  var connection: HealthCLI.AppConnection {
    HealthCLI.AppConnection(
      isRunning: { true }, signal: { self.respond() }, open: { _ in },
      sleep: { _ in Thread.sleep(forTimeInterval: 0.01) })
  }

  private func respond() {
    Thread.detachNewThread { [self] in
      for request in (try? folder.access.claimActions()) ?? [] {
        asked.withLock { $0.append(request.action) }
        guard case .downloadBlob(let sha256) = request.action, let data = blobs[sha256] else {
          try? folder.access.finish(
            id: request.id,
            outcome: .failed(
              AgentActionFailure(
                reason: .failed,
                message: "lil health couldn't download the route's points. Check that this Mac "
                  + "is online, then try again.")))
          continue
        }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? data.write(to: cache.appending(path: sha256))
        try? folder.access.finish(id: request.id, outcome: .ok(.done))
      }
    }
  }
}

@Suite
struct RouteToolsTests {
  let folder: AppFolder
  let cache: URL
  let blobs: [String: Data]

  init() async throws {
    folder = try AppFolder()
    try await Conformance.sync(into: folder.database, pins: nil)
    try folder.access.setEnabled(true)
    cache = folder.directory.appending(path: "HealthBlobs")
    blobs = try datasetBlobs()
  }

  private func connect(_ app: HealthCLI.AppConnection) async throws -> MCPConnection {
    try await MCPConnection(
      folder.directory, now: try Conformance.date("2026-10-20T15:00:00Z"), app: app,
      blobDirectory: cache)
  }

  @Test
  func asksTheAppForPointsItHasntDownloaded() async throws {
    let app = BlobApp(folder, cache: cache, blobs: blobs)
    let connection = try await connect(app.connection)
    let first = try await connection.call("workout_route", ["id": .string(run)])
    #expect(first.isError == false, "\(first.text)")
    // The 31 it has, less one with invalid coordinates.
    #expect(first.text.contains(#""pointCount":30"#))
    // Then from the cache, without asking again.
    let second = try await connection.call("workout_route_points", ["id": .string(run)])
    await connection.close()
    #expect(second.isError == false, "\(second.text)")
    let asked = app.asked.withLock { $0 }
    #expect(asked.count == 1)
    guard case .downloadBlob(let sha256) = asked.first else {
      Issue.record("Asked for \(asked)")
      return
    }
    #expect(blobs[sha256] != nil)
    // Never logged: the tool calls are.
    #expect(try folder.access.entries().map(\.command).allSatisfy { $0.hasPrefix("workout_route") })
  }

  @Test
  func asksAgainForPointsDamagedInTheCache() async throws {
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    for sha256 in blobs.keys {
      try Data("damaged".utf8).write(to: cache.appending(path: sha256))
    }
    let app = BlobApp(folder, cache: cache, blobs: blobs)
    let connection = try await connect(app.connection)
    let result = try await connection.call("workout_route", ["id": .string(run)])
    await connection.close()
    #expect(result.isError == false, "\(result.text)")
    #expect(app.asked.withLock { $0.count } == 1)
  }

  @Test
  func saysWhyItCouldntGetThePoints() async throws {
    let offline = BlobApp(folder, cache: cache, blobs: [:])
    var connection = try await connect(offline.connection)
    var result = try await connection.call("workout_route", ["id": .string(run)])
    await connection.close()
    #expect(result.isError == true)
    #expect(
      result.text
        == "lil health couldn't download the route's points. Check that this Mac is online, then "
        + "try again.")

    connection = try await connect(.notInstalled)
    result = try await connection.call("workout_route", ["id": .string(run)])
    await connection.close()
    #expect(result.isError == true)
    #expect(result.text == "lil health isn't installed.")
  }

  @Test
  func commandsReadAsText() throws {
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    for (sha256, data) in blobs { try data.write(to: cache.appending(path: sha256)) }
    func run(_ arguments: String...) throws -> String {
      let outcome = HealthCLI.run(
        arguments,
        context: HealthCLI.Context(
          directory: folder.directory, now: { try! Conformance.date("2026-10-20T15:00:00Z") },
          process: "zsh", timeZone: "UTC", blobDirectory: cache))
      #expect(outcome.status == 0, "\(outcome.error)")
      return outcome.output
    }
    #expect(
      try run("routes", "--date", "2026-10-20") == """
        Workout routes, M: 2026-09-21 to 2026-10-20 (UTC)
        3 routes

          2026-10-18 07:00   30m   31 points   Test Apple Watch   workout 0c0f0000-0000-4000-8000-000000000013   0c0f0000-0000-4000-8000-000000000173
          2026-10-16 08:00   20m   5 points   Test Cycling App   no workout   0c0f0000-0000-4000-8000-000000000175
          2026-10-13 18:01   38m   9 points   Test Apple Watch   no workout   0c0f0000-0000-4000-8000-000000000171

        """)
    #expect(
      try run("route", "0c0f0000-0000-4000-8000-000000000013") == """
        Route 0c0f0000-0000-4000-8000-000000000173   2026-10-18 07:00   30m (UTC)
        Workout 0c0f0000-0000-4000-8000-000000000013, from Test Apple Watch

        3.36 km   climbed 16.2 m   descended 16.2 m   30 points
        Starts near 51.5, -0.12, ends near 51.5, -0.12

        Shape: 4 of its points, within 5 m
          2026-10-18 07:00   51.5, -0.12   10 m
          2026-10-18 07:10   51.509, -0.12   20 m
          2026-10-18 07:20   51.509, -0.106   25 m
          2026-10-18 07:30   51.5, -0.12   10 m

        Every point: route 0c0f0000-0000-4000-8000-000000000173 --points

        """)
    #expect(
      try run("route", "0c0f0000-0000-4000-8000-000000000173", "--points", "--limit", "2") == """
        Route 0c0f0000-0000-4000-8000-000000000173: 2 of its 30 points (UTC)

          2026-10-18 07:00:00   51.5, -0.12   10 m   1.67 m/s   0°   ±4.2 m
          2026-10-18 07:01:00   51.5009, -0.12   11 m   1.67 m/s   0°   ±4.2 m

        More: --points --cursor 2

        """)
  }
}
