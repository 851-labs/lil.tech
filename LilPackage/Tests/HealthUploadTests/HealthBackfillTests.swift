import Dependencies
import Foundation
import GzipFiles
import Testing

@testable import HealthUpload

// Synthetic data only (AGENTS.md).
private let steps = HealthBackfillType(id: "HKQuantityTypeIdentifierStepCount")
private let sleep = HealthBackfillType(id: "HKCategoryTypeIdentifierSleepAnalysis")
private let heartRate = HealthBackfillType(id: "HKQuantityTypeIdentifierHeartRate")

/// A fake HealthKit: each type's history is `pages` pages of `perPage` records. Anchors are the
/// number of pages read so far.
private final class FakeHealth: Sendable {
  /// Each type's pages so far; adding one is new data.
  let pageCounts: LockIsolated<[String: Int]>
  let perPage = 3
  let reads = LockIsolated<[String]>([])

  init(pages: [String: Int]) {
    self.pageCounts = LockIsolated(pages)
  }

  var reader: HealthReader {
    HealthReader { [self] type, anchor, _ in
      let read = anchor.map { Int(String(decoding: $0, as: UTF8.self))! } ?? 0
      reads.withValue { $0.append("\(type.id.suffix(9))@\(read)") }
      let total = pageCounts.value[type.id] ?? 0
      let records = read < total ? perPage : 0
      let mutations = (0..<records).map { n in
        HealthMutation.delete("health_sample", id: "\(type.id)-\(read)-\(n)")
      }
      return HealthPage(
        mutations: mutations, anchor: Data(String(min(read + 1, total)).utf8),
        hasMore: read + 1 < total)
    }
  }
}

/// A fake server: records accepted batch IDs and the IDs of the records in them.
private final class FakeServer: Sendable {
  let accepted = LockIsolated<[String]>([])
  let records = LockIsolated<Set<String>>([])
  /// Upload attempts (1-based) that fail.
  let failing = LockIsolated<Set<Int>>([])
  let attempts = LockIsolated(0)

  struct Offline: Error {}

  var uploader: HealthBatchUploader {
    HealthBatchUploader { [self] id, file in
      let attempt = attempts.withValue {
        $0 += 1
        return $0
      }
      if failing.value.contains(attempt) { throw Offline() }
      accepted.withValue { $0.append(id) }
      let lines = String(decoding: try Gzip.decompress(file), as: UTF8.self).split(separator: "\n")
      for line in lines {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let id = object?["id"] as? String ?? ""
        records.withValue { _ = $0.insert(id) }
      }
    }
  }
}

private func makeBackfill(
  _ types: [HealthBackfillType], health: FakeHealth, server: FakeServer,
  storage: HealthBackfillStorage
) -> HealthBackfill {
  withDependencies {
    $0.healthReader = health.reader
    $0.healthBatchUploader = server.uploader
    $0.healthBackfillStorage = storage
    $0.uuid = .incrementing
  } operation: {
    HealthBackfill(types: types)
  }
}

struct HealthBackfillTests {
  @Test
  func uploadsEveryPageOfEveryType() async throws {
    let health = FakeHealth(pages: [steps.id: 2, sleep.id: 1])
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill([steps, sleep], health: health, server: server, storage: storage)

    try await backfill.run()

    #expect(health.reads.value == ["StepCount@0", "StepCount@1", "pAnalysis@0"])
    #expect(server.records.value.count == 9)
    #expect(server.accepted.value.count == 3)
    let state = try #require(try storage.loadState())
    #expect(state.finished == [steps.id, sleep.id])
    #expect(state.pending == nil)
    #expect(state.uploadedRecords == 9)
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(
      await updates.next()
        == .init(
          finishedTypes: 2, totalTypes: 2, uploadedRecords: 9, isRunning: false, failure: nil))

    // Running again catches every type up from its anchor: nothing new, so nothing uploaded.
    try await backfill.run()
    #expect(health.reads.value.count == 5)
    #expect(server.accepted.value.count == 3)
  }

  @Test
  func aFailedPageIsReadAgainNextTime() async throws {
    let health = FakeHealth(pages: [steps.id: 2])
    let server = FakeServer()
    server.failing.setValue([2])
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill([steps], health: health, server: server, storage: storage)

    await #expect(throws: FakeServer.Offline.self) { try await backfill.run() }
    // The first page's anchor is committed; the second page is dropped, files and all.
    let stopped = try #require(try storage.loadState())
    #expect(stopped.anchors[steps.id] == Data("1".utf8))
    #expect(stopped.pending == nil)
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await updates.next()?.failure != nil)

    try await backfill.run()
    #expect(health.reads.value == ["StepCount@0", "StepCount@1", "StepCount@1"])
    #expect(try storage.loadState()?.finished == [steps.id])
    #expect(server.records.value.count == 6)
    var after = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await after.next()?.failure == nil)
  }

  @Test
  func aFailingTypeDoesntHoldUpTheOthers() async throws {
    let health = FakeHealth(pages: [steps.id: 1, sleep.id: 1])
    let broken = LockIsolated(true)
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      $0.healthReader = HealthReader { type, anchor, limit in
        if type == steps, broken.value { throw FakeServer.Offline() }
        return try await health.reader.page(type, anchor, limit)
      }
      $0.healthBatchUploader = server.uploader
      $0.healthBackfillStorage = storage
      $0.uuid = .incrementing
    } operation: {
      HealthBackfill(types: [steps, sleep])
    }

    await #expect(throws: FakeServer.Offline.self) { try await backfill.run() }
    #expect(try storage.loadState()?.finished == [sleep.id])

    // Steps is tried again with the next change, whatever it's for.
    broken.setValue(false)
    try await backfill.syncChanges(of: [])
    #expect(try storage.loadState()?.finished == [steps.id, sleep.id])
  }

  @Test
  func changesWaitForABackfill() async throws {
    let health = FakeHealth(pages: [steps.id: 1])
    let backfill = makeBackfill(
      [steps], health: health, server: FakeServer(), storage: .inMemory())
    try await backfill.syncChanges(of: [steps.id])
    #expect(health.reads.value.isEmpty)
  }

  @Test
  func aRunKilledAfterUploadingResendsTheSameBatches() async throws {
    // The app was killed after the server accepted the page, before its anchor was saved.
    let health = FakeHealth(pages: [steps.id: 1])
    let storage = HealthBackfillStorage.inMemory()
    var state = HealthBackfillState()
    let file = try #require(
      try {
        var writer = HealthBatchWriter()
        _ = try writer.append(.delete("health_sample", id: "already-sent"))
        return try writer.finish()
      }())
    try storage.saveFile("batch-1", file)
    state.pending = .init(
      type: steps.id, anchor: Data("1".utf8), isLast: true, batches: ["batch-1"], records: 1)
    try storage.saveState(state)
    let server = FakeServer()
    let backfill = makeBackfill([steps], health: health, server: server, storage: storage)

    try await backfill.run()

    #expect(server.accepted.value == ["batch-1"])
    // Only the catch-up read, from the anchor the pending page committed.
    #expect(health.reads.value == ["StepCount@1"])
    #expect(try storage.loadState()?.finished == [steps.id])
  }

  @Test
  func aTypeWithNothingKeepsNoAnchorAndIsCheckedAgain() async throws {
    // No data, or no permission: HealthKit doesn't say which.
    let health = FakeHealth(pages: [:])
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill([steps], health: health, server: server, storage: storage)

    try await backfill.run()

    #expect(server.accepted.value.isEmpty)
    let state = try #require(try storage.loadState())
    #expect(state.empty == [steps.id])
    #expect(state.finished.isEmpty)
    #expect(state.anchors.isEmpty)
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await updates.next()?.isFinished == true)

    try await backfill.run()
    #expect(health.reads.value == ["StepCount@0", "StepCount@0"])
  }

  @Test
  func aPageWhoseFilesWerentWrittenIsReadAgain() async throws {
    // The app was killed after saving the pending page, before writing its file.
    let health = FakeHealth(pages: [steps.id: 1])
    let storage = HealthBackfillStorage.inMemory()
    var state = HealthBackfillState()
    state.pending = .init(
      type: steps.id, anchor: Data("1".utf8), isLast: true, batches: ["never-written"],
      records: 3)
    try storage.saveState(state)
    let server = FakeServer()
    let backfill = makeBackfill([steps], health: health, server: server, storage: storage)

    try await backfill.run()

    #expect(health.reads.value == ["StepCount@0"])
    #expect(server.records.value.count == 3)
    #expect(try storage.loadState()?.uploadedRecords == 3)
  }

  @Test
  func unreadableStateStartsOver() async throws {
    let health = FakeHealth(pages: [steps.id: 1])
    let server = FakeServer()
    let cleared = LockIsolated(false)
    var storage = HealthBackfillStorage.inMemory()
    let inMemory = storage
    storage.loadState = {
      guard cleared.value else {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "corrupt"))
      }
      return try inMemory.loadState()
    }
    storage.saveState = { state in
      if state == nil { cleared.setValue(true) }
      try inMemory.saveState(state)
    }
    let backfill = makeBackfill([steps], health: health, server: server, storage: storage)

    await withKnownIssue {
      try await backfill.run()
    }
    #expect(server.records.value.count == 3)
  }

  @Test
  func resetStopsTheRun() async throws {
    let (started, didStart) = AsyncStream<Void>.makeStream()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      $0.healthReader = HealthReader { _, _, _ in
        didStart.yield()
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
      }
      $0.healthBatchUploader = FakeServer().uploader
      $0.healthBackfillStorage = storage
      $0.uuid = .incrementing
    } operation: {
      HealthBackfill(types: [steps])
    }
    let task = Task { try await backfill.run() }
    for await _ in started { break }
    await backfill.reset()
    await #expect(throws: CancellationError.self) { try await task.value }
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await updates.next()?.isRunning == false)
  }

  @Test
  func resetStartsOver() async throws {
    let health = FakeHealth(pages: [steps.id: 1])
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill([steps], health: health, server: server, storage: storage)
    try await backfill.run()

    await backfill.reset()
    #expect(try storage.loadState() == nil)
    try await backfill.run()
    #expect(health.reads.value == ["StepCount@0", "StepCount@0"])
  }

  @Test
  func directoryStorageKeepsStateAndFiles() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = HealthBackfillStorage.directory(directory)
    #expect(try storage.loadState() == nil)
    var state = HealthBackfillState()
    state.finished = [steps.id]
    try storage.saveState(state)
    try storage.saveFile("a", Data([1, 2, 3]))
    #expect(try storage.loadState() == state)
    #expect(try storage.loadFile("a") == Data([1, 2, 3]))
    try storage.removeFile("a")
    #expect(try storage.loadFile("a") == nil)
    try storage.saveState(nil)
    #expect(try storage.loadState() == nil)
  }

  @Test
  func uploadsChangesSinceTheAnchors() async throws {
    let health = FakeHealth(pages: [steps.id: 1, sleep.id: 1])
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill([steps, sleep], health: health, server: server, storage: storage)
    try await backfill.run()

    // A new page of steps; sleep didn't change, so it isn't read.
    health.pageCounts.withValue { $0[steps.id] = 2 }
    try await backfill.syncChanges(of: [steps.id])

    #expect(health.reads.value == ["StepCount@0", "pAnalysis@0", "StepCount@1"])
    #expect(server.records.value.count == 9)
    #expect(try storage.loadState()?.anchors[steps.id] == Data("2".utf8))
  }

  @Test
  func changesDuringARunJoinIt() async throws {
    let health = FakeHealth(pages: [steps.id: 1, sleep.id: 1, heartRate.id: 1])
    let (started, didStart) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    let blocked = LockIsolated(true)
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      $0.healthReader = HealthReader { type, anchor, limit in
        if blocked.value {
          blocked.setValue(false)
          didStart.yield()
          for await _ in release {}
        }
        return try await health.reader.page(type, anchor, limit)
      }
      $0.healthBatchUploader = server.uploader
      $0.healthBackfillStorage = storage
      $0.uuid = .incrementing
    } operation: {
      HealthBackfill(types: [steps, sleep, heartRate])
    }

    try storage.saveState(HealthBackfillState())
    async let first: Void = backfill.syncChanges(of: [steps.id])
    for await _ in started { break }
    // A burst while steps is being read: picked up by the same run.
    async let second: Void = backfill.syncChanges(of: [sleep.id])
    async let third: Void = backfill.syncChanges(of: [heartRate.id])
    while await !backfill.requestedTypes.isSuperset(of: [sleep.id, heartRate.id]) {
      await Task.yield()
    }
    finish.finish()
    _ = try await (first, second, third)

    #expect(health.reads.value == ["StepCount@0", "pAnalysis@0", "HeartRate@0"])
  }

  @Test
  func observerCompletionDoesntWaitPastTheDeadline() async {
    let (release, finish) = AsyncStream<Void>.makeStream()
    let finished = LockIsolated(false)
    await HealthObserver.handle(steps.id, deadline: .milliseconds(10)) { _ in
      for await _ in release {}
      finished.setValue(true)
    }
    // Handled, while the work goes on.
    #expect(!finished.value)
    finish.finish()
  }
}
