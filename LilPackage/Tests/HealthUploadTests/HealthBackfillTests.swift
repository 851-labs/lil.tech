import Dependencies
import Foundation
import GzipFiles
import Testing

@testable import HealthUpload

// Synthetic data only (AGENTS.md).
// Discrete types, so these tests are only about the page loop; statistics have their own.
private let temperature = HealthBackfillType(id: "HKQuantityTypeIdentifierBodyTemperature")
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
      let name = type.id.components(separatedBy: "Identifier").last ?? type.id
      reads.withValue { $0.append("\(name)@\(read)") }
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
    $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
  } operation: {
    HealthBackfill(types: types)
  }
}

struct HealthBackfillTests {
  @Test
  func uploadsEveryPageOfEveryType() async throws {
    let health = FakeHealth(pages: [temperature.id: 2, sleep.id: 1])
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(
      [temperature, sleep], health: health, server: server, storage: storage)

    try await backfill.run()

    #expect(health.reads.value == ["BodyTemperature@0", "BodyTemperature@1", "SleepAnalysis@0"])
    #expect(server.records.value.count == 9)
    #expect(server.accepted.value.count == 3)
    let state = try #require(try storage.loadState())
    #expect(state.finished == [temperature.id, sleep.id])
    #expect(state.pending == nil)
    #expect(state.uploadedRecords == 9)
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(
      await updates.next()
        == .init(
          finishedTypes: 2, totalTypes: 2, uploadedRecords: 9, isRunning: false, failure: nil,
          types: [
            temperature.id: .init(isDone: true, uploadedRecords: 6),
            sleep.id: .init(isDone: true, uploadedRecords: 3),
          ],
          lastUploadAt: Date(timeIntervalSince1970: 1_760_400_000)))

    // Running again catches every type up from its anchor: nothing new, so nothing uploaded.
    try await backfill.run()
    #expect(health.reads.value.count == 5)
    #expect(server.accepted.value.count == 3)
  }

  @Test
  func aFailedPageIsReadAgainNextTime() async throws {
    let health = FakeHealth(pages: [temperature.id: 2])
    let server = FakeServer()
    server.failing.setValue([2])
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill([temperature], health: health, server: server, storage: storage)

    await #expect(throws: FakeServer.Offline.self) { try await backfill.run() }
    // The first page's anchor is committed; the second page is dropped, files and all.
    let stopped = try #require(try storage.loadState())
    #expect(stopped.anchors[temperature.id] == Data("1".utf8))
    #expect(stopped.pending == nil)
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await updates.next()?.failure != nil)

    try await backfill.run()
    #expect(health.reads.value == ["BodyTemperature@0", "BodyTemperature@1", "BodyTemperature@1"])
    #expect(try storage.loadState()?.finished == [temperature.id])
    #expect(server.records.value.count == 6)
    var after = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await after.next()?.failure == nil)
  }

  @Test
  func aFailingTypeDoesntHoldUpTheOthers() async throws {
    let health = FakeHealth(pages: [temperature.id: 1, sleep.id: 1])
    let broken = LockIsolated(true)
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      $0.healthReader = HealthReader { type, anchor, limit in
        if type == temperature, broken.value { throw FakeServer.Offline() }
        return try await health.reader.page(type, anchor, limit)
      }
      $0.healthBatchUploader = server.uploader
      $0.healthBackfillStorage = storage
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature, sleep])
    }

    await #expect(throws: FakeServer.Offline.self) { try await backfill.run() }
    #expect(try storage.loadState()?.finished == [sleep.id])

    // Steps is tried again with the next change, whatever it's for.
    broken.setValue(false)
    try await backfill.syncChanges(of: [])
    #expect(try storage.loadState()?.finished == [temperature.id, sleep.id])
  }

  @Test
  func changesWaitForABackfill() async throws {
    let health = FakeHealth(pages: [temperature.id: 1])
    let backfill = makeBackfill(
      [temperature], health: health, server: FakeServer(), storage: .inMemory())
    try await backfill.syncChanges(of: [temperature.id])
    #expect(health.reads.value.isEmpty)
  }

  @Test
  func aRunKilledAfterUploadingResendsTheSameBatches() async throws {
    // The app was killed after the server accepted the page, before its anchor was saved.
    let health = FakeHealth(pages: [temperature.id: 1])
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
      type: temperature.id, anchor: Data("1".utf8), isLast: true, batches: ["batch-1"], records: 1)
    try storage.saveState(state)
    let server = FakeServer()
    let backfill = makeBackfill([temperature], health: health, server: server, storage: storage)

    try await backfill.run()

    #expect(server.accepted.value == ["batch-1"])
    // Only the catch-up read, from the anchor the pending page committed.
    #expect(health.reads.value == ["BodyTemperature@1"])
    #expect(try storage.loadState()?.finished == [temperature.id])
  }

  @Test
  func aTypeWithNothingKeepsNoAnchorAndIsCheckedAgain() async throws {
    // No data, or no permission: HealthKit doesn't say which.
    let health = FakeHealth(pages: [:])
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill([temperature], health: health, server: server, storage: storage)

    try await backfill.run()

    #expect(server.accepted.value.isEmpty)
    let state = try #require(try storage.loadState())
    #expect(state.empty == [temperature.id])
    #expect(state.finished.isEmpty)
    #expect(state.anchors.isEmpty)
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await updates.next()?.isFinished == true)

    try await backfill.run()
    #expect(health.reads.value == ["BodyTemperature@0", "BodyTemperature@0"])
  }

  @Test
  func aPageWhoseFilesWerentWrittenIsReadAgain() async throws {
    // The app was killed after saving the pending page, before writing its file.
    let health = FakeHealth(pages: [temperature.id: 1])
    let storage = HealthBackfillStorage.inMemory()
    var state = HealthBackfillState()
    state.pending = .init(
      type: temperature.id, anchor: Data("1".utf8), isLast: true, batches: ["never-written"],
      records: 3)
    try storage.saveState(state)
    let server = FakeServer()
    let backfill = makeBackfill([temperature], health: health, server: server, storage: storage)

    try await backfill.run()

    #expect(health.reads.value == ["BodyTemperature@0"])
    #expect(server.records.value.count == 3)
    #expect(try storage.loadState()?.uploadedRecords == 3)
  }

  @Test
  func unreadableStateStartsOver() async throws {
    let health = FakeHealth(pages: [temperature.id: 1])
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
    let backfill = makeBackfill([temperature], health: health, server: server, storage: storage)

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
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature])
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
    let health = FakeHealth(pages: [temperature.id: 1])
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill([temperature], health: health, server: server, storage: storage)
    try await backfill.run()

    await backfill.reset()
    #expect(try storage.loadState() == nil)
    try await backfill.run()
    #expect(health.reads.value == ["BodyTemperature@0", "BodyTemperature@0"])
  }

  @Test
  func directoryStorageKeepsStateAndFiles() throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = HealthBackfillStorage.directory(directory)
    #expect(try storage.loadState() == nil)
    var state = HealthBackfillState()
    state.finished = [temperature.id]
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
    let health = FakeHealth(pages: [temperature.id: 1, sleep.id: 1])
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(
      [temperature, sleep], health: health, server: server, storage: storage)
    try await backfill.run()

    // A new page of temperature; sleep didn't change, so it isn't read.
    health.pageCounts.withValue { $0[temperature.id] = 2 }
    try await backfill.syncChanges(of: [temperature.id])

    #expect(health.reads.value == ["BodyTemperature@0", "SleepAnalysis@0", "BodyTemperature@1"])
    #expect(server.records.value.count == 9)
    #expect(try storage.loadState()?.anchors[temperature.id] == Data("2".utf8))
  }

  @Test
  func changesDuringARunJoinIt() async throws {
    let health = FakeHealth(pages: [temperature.id: 1, sleep.id: 1, heartRate.id: 1])
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
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature, sleep, heartRate])
    }

    try storage.saveState(HealthBackfillState())
    async let first: Void = backfill.syncChanges(of: [temperature.id])
    for await _ in started { break }
    // A burst while temperature is being read: picked up by the same run.
    async let second: Void = backfill.syncChanges(of: [sleep.id])
    async let third: Void = backfill.syncChanges(of: [heartRate.id])
    while await !backfill.requestedTypes.isSuperset(of: [sleep.id, heartRate.id]) {
      await Task.yield()
    }
    finish.finish()
    _ = try await (first, second, third)

    #expect(health.reads.value == ["BodyTemperature@0", "SleepAnalysis@0", "HeartRate@0"])
  }

  @Test
  func observerCompletionDoesntWaitPastTheDeadline() async {
    let (release, finish) = AsyncStream<Void>.makeStream()
    let finished = LockIsolated(false)
    await HealthObserver.handle(temperature.id, deadline: .milliseconds(10)) { _ in
      for await _ in release {}
      finished.setValue(true)
    }
    // Handled, while the work goes on.
    #expect(!finished.value)
    finish.finish()
  }

  @Test
  func aPausedRunResumesWithItsPendingPage() async throws {
    let health = FakeHealth(pages: [temperature.id: 1])
    let (started, didStart) = AsyncStream<Void>.makeStream()
    let blocking = LockIsolated(true)
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      $0.healthReader = health.reader
      $0.healthBatchUploader = HealthBatchUploader { id, file in
        if blocking.value {
          didStart.yield()
          // Like URLSession, a cancelled upload fails with a URL error.
          do { try await Task.sleep(for: .seconds(60)) } catch { throw URLError(.cancelled) }
        }
        try await server.uploader.upload(id, file)
      }
      $0.healthBackfillStorage = storage
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature])
    }

    let run = Task { try await backfill.run() }
    for await _ in started { break }
    // The background task's time is up.
    await backfill.pause()
    await #expect(throws: CancellationError.self) { try await run.value }
    let paused = try #require(try storage.loadState()?.pending)
    #expect(try storage.loadFile(paused.batches[0]) != nil)
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await updates.next()?.failure == nil)

    blocking.setValue(false)
    try await backfill.run()
    #expect(server.accepted.value == paused.batches)
    #expect(health.reads.value.first == "BodyTemperature@0")
    #expect(try storage.loadState()?.finished == [temperature.id])
  }

  @Test
  func aLockedDeviceStopsTheRunWithoutAFailure() async throws {
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      $0.healthReader = HealthReader { _, _, _ in throw HealthReader.Locked() }
      $0.healthBatchUploader = FakeServer().uploader
      $0.healthBackfillStorage = storage
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature, sleep])
    }

    await #expect(throws: HealthReader.Locked.self) { try await backfill.run() }
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    let progress = await updates.next()
    #expect(progress?.failure == nil)
    #expect(progress?.isRunning == false)
    #expect(try storage.loadState()?.finished.isEmpty ?? true)
  }

  @Test
  func aFullAccountStopsTheRunAndKeepsThePage() async throws {
    let health = FakeHealth(pages: [temperature.id: 1, sleep.id: 1])
    let full = LockIsolated(true)
    let attempts = LockIsolated(0)
    let date = LockIsolated(Date(timeIntervalSince1970: 1_760_400_000))
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      $0.healthReader = health.reader
      $0.healthBatchUploader = HealthBatchUploader { id, file in
        attempts.withValue { $0 += 1 }
        if full.value { throw HealthBatchUploader.StorageFull() }
        try await server.uploader.upload(id, file)
      }
      $0.healthBackfillStorage = storage
      $0.uuid = .incrementing
      $0.date = DateGenerator { date.value }
    } operation: {
      HealthBackfill(types: [temperature, sleep])
    }

    await #expect(throws: HealthBatchUploader.StorageFull.self) { try await backfill.run() }
    // Every other upload would be refused too, so the other type isn't tried, but it's asked
    // for again.
    #expect(attempts.value == 1)
    #expect(health.reads.value == ["BodyTemperature@0"])
    #expect(await backfill.requestedTypes == [temperature.id, sleep.id])
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    let progress = await updates.next()
    #expect(progress?.isStorageFull == true)
    #expect(progress?.isOffline == false)
    #expect(progress?.failure == "Your lil account's storage is full")
    // The page is kept, and goes up once there's room.
    let pending = try #require(try storage.loadState()?.pending)

    // Changes wait a while rather than being refused on every HealthKit wake.
    full.setValue(false)
    try await backfill.syncChanges(of: [sleep.id])
    #expect(attempts.value == 1)

    // Once that's up, a sync of changes that goes through shows there's room again.
    date.withValue { $0.addTimeInterval(HealthBackfill.storageFullRetryInterval) }
    try await backfill.syncChanges(of: [sleep.id])
    #expect(server.accepted.value.prefix(pending.batches.count) == pending.batches[...])
    #expect(try storage.loadState()?.finished == [temperature.id, sleep.id])
    let cleared = await updates.next()
    #expect(cleared?.isStorageFull == false)
    #expect(cleared?.failure == nil)
  }

  @Test
  func aFullAccountIsTriedRightAwayByAFullRun() async throws {
    let full = LockIsolated(true)
    let server = FakeServer()
    let backfill = withDependencies {
      $0.healthReader = FakeHealth(pages: [temperature.id: 1]).reader
      $0.healthBatchUploader = HealthBatchUploader { id, file in
        if full.value { throw HealthBatchUploader.StorageFull() }
        try await server.uploader.upload(id, file)
      }
      $0.healthBackfillStorage = .inMemory()
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature])
    }
    await #expect(throws: HealthBatchUploader.StorageFull.self) { try await backfill.run() }
    full.setValue(false)
    // Try Again.
    try await backfill.run()
    #expect(server.accepted.value.count == 1)
  }

  @Test
  func aRateLimitPausesUploadsUntilItsOver() async throws {
    let health = FakeHealth(pages: [temperature.id: 1, sleep.id: 1])
    let limited = LockIsolated(true)
    let attempts = LockIsolated(0)
    let clock = TestClock()
    let date = LockIsolated(Date(timeIntervalSince1970: 1_760_400_000))
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      $0.healthReader = health.reader
      $0.healthBatchUploader = HealthBatchUploader { id, file in
        attempts.withValue { $0 += 1 }
        if limited.value {
          limited.setValue(false)
          throw HealthBatchUploader.RateLimited(retryAfter: 60)
        }
        try await server.uploader.upload(id, file)
      }
      $0.healthBackfillStorage = storage
      $0.uuid = .incrementing
      $0.date = DateGenerator { date.value }
      $0.continuousClock = clock
    } operation: {
      HealthBackfill(types: [temperature, sleep])
    }

    await #expect(throws: HealthBatchUploader.RateLimited.self) { try await backfill.run() }
    // Paused, not failed, with its page kept and the other type asked for again.
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await updates.next()?.failure == nil)
    #expect(try storage.loadState()?.pending != nil)
    #expect(await backfill.requestedTypes == [temperature.id, sleep.id])

    // Changes wait for the limit to pass.
    try await backfill.syncChanges(of: [sleep.id])
    #expect(attempts.value == 1)

    // A run of everything waits it out, then goes.
    let run = Task { try await backfill.run() }
    await Task.megaYield()
    #expect(attempts.value == 1)
    date.withValue { $0.addTimeInterval(60) }
    await clock.advance(by: .seconds(60))
    try await run.value
    #expect(try storage.loadState()?.finished == [temperature.id, sleep.id])
  }

  @Test
  func networkFailuresAreOffline() {
    #expect(HealthBackfill.isOffline(URLError(.notConnectedToInternet)))
    #expect(!HealthBackfill.isOffline(HealthBatchUploader.Rejected(statusCode: 503)))
    // A slow server isn't the phone being offline.
    #expect(!HealthBackfill.isOffline(URLError(.timedOut)))
  }
}
