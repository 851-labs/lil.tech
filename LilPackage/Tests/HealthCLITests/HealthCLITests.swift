import Foundation
import GRDB
import HealthAgentAccess
import HealthDatabase
import HealthTools
import SQLiteData
import Testing

@testable import HealthCLI

// Synthetic data only (AGENTS.md).
private let device = "dev_000000000000000000000000ph"
private let steps = "HKQuantityTypeIdentifierStepCount"
/// Tuesday, October 20, 2026, 15:00 UTC.
private let now = Date(timeIntervalSince1970: 1_792_508_400)

/// `hours` after midnight UTC on October `day`, 2026.
private func utc(_ hours: Double, day: Int = 20) -> Date {
  Date(timeIntervalSince1970: 1_792_454_400 + Double(day - 20) * 86_400 + hours * 3600)
}

/// An app folder in a temporary directory, with a synthetic `Health.sqlite` the way the app makes
/// it (a WAL database, migrated) and the agent access store.
struct AppFolder {
  let directory: URL
  let database: DatabasePool
  let access: AgentAccessStore

  /// At `location`, or in a new temporary directory.
  init(migrated: Bool = true, at location: URL? = nil) throws {
    directory =
      location
      ?? FileManager.default.temporaryDirectory.appending(
        path: "HealthCLITests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    database = try DatabasePool(path: directory.appending(path: "Health.sqlite").path)
    if migrated { try HealthDatabase.migrator.migrate(database) }
    access = AgentAccessStore(directory: directory)
  }

  func run(_ arguments: String...) -> HealthCLI.Outcome {
    HealthCLI.run(
      arguments, context: HealthCLI.Context(directory: directory, now: { now }, process: "zsh"))
  }

  /// A week of steps, as the iPhone's statistics.
  func addSteps() throws {
    try database.write { db in
      try HealthStatisticsDevice.insert {
        HealthStatisticsDevice(
          id: device, device: device, pairedWithWatch: true,
          reportedAt: utc(14).unixMilliseconds)
      }
      .execute(db)
      try HealthStatistic.insert {
        for (day, sum) in [(14, 4000.0), (15, 1500), (17, 7000), (20, 3200)] {
          HealthStatistic(
            id: "\(device)/\(steps)@\(utc(9, day: day).unixMilliseconds)", device: device,
            type: steps, bucketStart: utc(9, day: day).unixMilliseconds, sum: sum, unit: "count")
        }
      }
      .execute(db)
    }
  }
}

@Suite
struct HealthCLITests {
  @Test
  func refusesWhileAccessIsOffAndLogsNothing() throws {
    let folder = try AppFolder()
    try folder.addSteps()
    let outcome = folder.run("summary")
    #expect(outcome.status == 77 && outcome.output.isEmpty)
    #expect(outcome.error.contains("Allow command-line and agent access"))
    // Off until the app turns it on: no file is made, and nothing is logged.
    #expect(
      !FileManager.default.fileExists(
        atPath: folder.directory.appending(path: AgentAccessStore.fileName).path))

    try folder.access.setEnabled(true, at: utc(0))
    try folder.access.setEnabled(false, at: utc(1))
    #expect(folder.run("metric", "Steps").status == 77)
    #expect(try folder.access.entries().isEmpty)
  }

  @Test
  func answersAndLogsEachQueryWhileAccessIsOn() throws {
    let folder = try AppFolder()
    try folder.addSteps()
    try folder.access.setEnabled(true)

    let summary = folder.run("summary", "--time-zone", "UTC")
    #expect(summary.status == 0 && summary.error.isEmpty)
    #expect(summary.output.contains("Summary for 2026-10-20 (UTC), everyday metrics"))
    #expect(summary.output.contains("3200 today · 15700 in the last 7 days"))

    let metric = folder.run("metric", "Steps", "--range", "W", "--json", "--time-zone", "UTC")
    #expect(metric.status == 0)
    let decoded = try JSONDecoder().decode(HealthMetricResult.self, from: Data(metric.output.utf8))
    let expected = try folder.database.read { db in
      try HealthTools(now: now).metric(type: steps, range: .week, timeZone: "UTC", db)
    }
    #expect(decoded == expected)
    #expect(decoded.buckets.map(\.value) == [4000, 1500, nil, 7000, nil, nil, 3200])
    // Every field is there, nulls included, as the toolkit's output schema requires.
    #expect(metric.output.contains(#""value" : null"#))

    _ = folder.run("search", "blood pressure")
    #expect(
      try folder.access.entries().map(\.command) == [
        "search 'blood pressure'",
        "metric Steps --range W --json --time-zone UTC",
        "summary --time-zone UTC",
      ])
    #expect(try folder.access.entries().allSatisfy { $0.process == "zsh" })
  }

  @Test
  func readsWhileTheAppIsWriting() throws {
    let folder = try AppFolder()
    try folder.addSteps()
    try folder.access.setEnabled(true)
    // The app, mid-write: a transaction it hasn't committed yet.
    try folder.database.writeWithoutTransaction { db in
      try db.beginTransaction()
      try db.execute(sql: #"DELETE FROM "healthStatistics""#)
      let outcome = folder.run("metric", steps, "--json", "--time-zone", "UTC")
      try db.rollback()
      #expect(outcome.status == 0)
      let metric = try JSONDecoder().decode(
        HealthMetricResult.self, from: Data(outcome.output.utf8))
      #expect(metric.value == 15_700)
    }
  }

  @Test
  func refusesADatabaseItDoesntKnowAndNeverMigrates() throws {
    let newer = try AppFolder()
    try newer.access.setEnabled(true)
    try newer.database.write { db in
      try db.execute(
        sql: "INSERT INTO grdb_migrations (identifier) VALUES ('From a later release')")
    }
    let outcome = newer.run("summary")
    #expect(outcome.status == 69 && outcome.error.contains("newer version of lil health"))

    let older = try AppFolder(migrated: false)
    try older.access.setEnabled(true)
    #expect(older.run("types").status == 69)
    // Read-only: it made no tables.
    #expect(try older.database.read { try $0.tableExists("healthSamples") } == false)

    let missing = try AppFolder()
    try FileManager.default.removeItem(at: missing.directory.appending(path: "Health.sqlite"))
    try missing.access.setEnabled(true)
    let none = missing.run("summary")
    #expect(none.status == 69 && none.error.contains("no lil health data on this Mac"))
  }

  @Test
  func reportsBadArgumentsAndDescribesItself() throws {
    let folder = try AppFolder()
    try folder.access.setEnabled(true)
    let unknown = folder.run("metric", "Nope")
    #expect(unknown.status == 65 && unknown.error.hasPrefix("lil-health: Unknown type: Nope."))
    #expect(folder.run("summary", "--time-zone", "+01:00").status == 65)
    #expect(folder.run("metric", "Steps", "--range", "Q").status == 64)
    #expect(folder.run("frobnicate").status == 64)

    #expect(folder.run("--describe") == HealthCLI.Outcome(output: HealthCLI.description + "\n"))
    let help = folder.run("--help")
    #expect(help.status == 0 && help.output.contains("USAGE: lil-health"))
    #expect(folder.run().output.contains("SUBCOMMANDS:"))
    // None of these were queries.
    #expect(
      try folder.access.entries().map(\.command) == ["summary --time-zone +01:00", "metric Nope"])
  }

  @Test
  func everyCommandAnswers() throws {
    let folder = try AppFolder()
    try folder.addSteps()
    try folder.access.setEnabled(true)
    for command in [
      ["summary"], ["types"], ["metric", "Steps", "-r", "6m"], ["samples", "Heart Rate"],
      ["workouts", "-r", "Y"], ["sleep"], ["medications"], ["details"], ["search", "steps"],
      ["sync", "status"],
    ] {
      for json in [false, true] {
        let arguments = command + (json ? ["--json"] : [])
        let outcome = HealthCLI.run(
          arguments,
          context: HealthCLI.Context(directory: folder.directory, now: { now }, process: "zsh"))
        #expect(outcome.status == 0, "\(arguments): \(outcome.error)")
        if json {
          #expect(
            (try? JSONSerialization.jsonObject(with: Data(outcome.output.utf8))) != nil,
            "\(arguments)")
        }
      }
    }
  }

  @Test
  func logsArgumentsAsAShellWouldTakeThem() {
    #expect(HealthCLI.commandLine(["metric", "Steps", "--range", "W"]) == "metric Steps --range W")
    #expect(HealthCLI.commandLine(["search", "it's", ""]) == #"search 'it'\''s' ''"#)
  }
}

/// Runs the built `lil-health` (the package's `lil-health-dev` product), as `lil help` and agents
/// do.
struct LilHealthExecutableTests {
  let tool = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(
    path: "lil-health-dev")

  @Test
  func describesItselfForLilHelp() throws {
    try #require(FileManager.default.isExecutableFile(atPath: tool.path), "no tool at \(tool.path)")
    let process = Process()
    process.executableURL = tool
    process.arguments = ["--describe"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: data, as: UTF8.self) == HealthCLI.description + "\n")
  }

  /// `lil-health mcp` as an agent runs it: JSON-RPC messages, one per line, on standard input and
  /// output. Its home is a temporary folder (`CFFIXED_USER_HOME`), so it reads a synthetic
  /// database in the app's folder there, never the real one.
  @Test
  func servesMCPOverStandardInputAndOutput() throws {
    try #require(FileManager.default.isExecutableFile(atPath: tool.path), "no tool at \(tool.path)")
    let home = FileManager.default.temporaryDirectory.appending(
      path: "HealthCLITests-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    let folder = try AppFolder(
      at: home.appending(path: "Library/Application Support/tech.lil.health"))
    try folder.addSteps()

    let process = Process()
    process.executableURL = tool
    process.arguments = ["mcp"]
    process.environment = ["CFFIXED_USER_HOME": home.path, "TZ": "UTC"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    // A server that stops answering fails the test rather than hanging it.
    let watchdog = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
    defer { watchdog.cancel() }

    var buffered = Data()
    /// Sends a request and reads lines until its response (requests may be answered out of
    /// order, but these are sent one at a time).
    func request(_ id: Int, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any]
    {
      let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
      input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: message) + [10])
      while true {
        if let newline = buffered.firstIndex(of: 10) {
          let line = buffered[..<newline]
          buffered = Data(buffered[(newline + 1)...])
          let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
          if response["id"] as? Int == id { return response }
          continue
        }
        let data = output.fileHandleForReading.availableData
        guard !data.isEmpty else { throw CocoaError(.fileReadUnknown) }
        buffered += data
      }
    }

    let initialized = try request(
      1, "initialize",
      [
        "protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
        "clientInfo": ["name": "HealthCLITests", "version": "1"],
      ])
    let server = (initialized["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
    #expect(server?["name"] as? String == "lil-health")
    input.fileHandleForWriting.write(
      Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8) + [10])

    let listed = try request(2, "tools/list")
    let tools = (listed["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    #expect(tools.compactMap { $0["name"] as? String }.first == "summary")
    #expect(tools.count == 10)

    // Access is off: the call fails with what to do, and isn't logged.
    let refused = try request(
      3, "tools/call", ["name": "summary", "arguments": [:] as [String: Any]])
    #expect((refused["result"] as? [String: Any])?["isError"] as? Bool == true)

    try folder.access.setEnabled(true)
    let summary = try request(
      4, "tools/call", ["name": "summary", "arguments": ["timeZone": "UTC"]])
    let result = summary["result"] as? [String: Any]
    #expect(result?["isError"] as? Bool == false)
    let structured = result?["structuredContent"] as? [String: Any]
    #expect(structured?["timeZone"] as? String == "UTC")
    #expect(try folder.access.entries().map(\.command) == [#"summary {"timeZone":"UTC"}"#])

    // Closing its input ends it.
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    #expect(process.terminationReason == .exit && process.terminationStatus == 0)
  }
}

private final class Marker {}
