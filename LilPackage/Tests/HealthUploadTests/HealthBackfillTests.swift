import Dependencies
import Foundation
import GzipFiles
import HealthKit
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
    $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
    $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
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
          // Every type finished, so every record is known.
          lastUploadAt: Date(timeIntervalSince1970: 1_760_400_000), totalRecords: 9))

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
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
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
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
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
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
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
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
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
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
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
  func missingConsentStopsTheRunAndKeepsThePage() async throws {
    let health = FakeHealth(pages: [temperature.id: 1, sleep.id: 1])
    let attempts = LockIsolated(0)
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      $0.healthReader = health.reader
      $0.healthBatchUploader = HealthBatchUploader { _, _ in
        attempts.withValue { $0 += 1 }
        throw HealthBatchUploader.ConsentRequired()
      }
      $0.healthBackfillStorage = storage
      $0.uuid = .incrementing
    } operation: {
      HealthBackfill(types: [temperature, sleep])
    }

    await #expect(throws: HealthBatchUploader.ConsentRequired.self) { try await backfill.run() }
    // Every other upload would be refused too.
    #expect(attempts.value == 1)
    #expect(await backfill.requestedTypes == [temperature.id, sleep.id])
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await updates.next()?.failure == "lil health needs your consent to upload Health data")
    #expect(try storage.loadState()?.pending != nil)
  }

  @Test
  func blobsGoUpBeforeTheBatchesThatReferToThem() async throws {
    // Synthetic payloads, e.g. ECG voltages.
    let voltages = Data((0..<1000).map { UInt8($0 % 251) })
    let route = Data("synthetic route".utf8)
    let uploads = LockIsolated<[String]>([])
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      $0.healthReader = HealthReader { _, anchor, _ in
        HealthPage(
          mutations: anchor == nil ? [.delete("health_sample", id: "ecg-1")] : [],
          // The same blob twice goes up once.
          blobs: anchor == nil ? [voltages, route, voltages] : [], anchor: Data("1".utf8),
          hasMore: false)
      }
      $0.healthBlobUploader = HealthBlobUploader { sha256, data in
        #expect(HealthBlob.sha256(data) == sha256)
        uploads.withValue { $0.append(sha256) }
      }
      $0.healthBatchUploader = HealthBatchUploader { _, _ in
        uploads.withValue { $0.append("batch") }
      }
      $0.healthBackfillStorage = storage
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature])
    }

    try await backfill.run()
    // The blobs go up at the same time, and both before the batch.
    #expect(uploads.value.count == 3)
    #expect(
      Set(uploads.value.prefix(2)) == [HealthBlob.sha256(voltages), HealthBlob.sha256(route)])
    #expect(uploads.value.last == "batch")
    // The files are gone once the page is uploaded.
    #expect(try storage.loadFile("blob-\(HealthBlob.sha256(voltages))") == nil)
    #expect(try storage.loadState()?.pending == nil)
  }

  @Test
  func aPageWithBlobsIsKeptUntilTheyGoUp() async throws {
    let voltages = Data((0..<1000).map { UInt8($0 % 251) })
    let sha256 = HealthBlob.sha256(voltages)
    let full = LockIsolated(true)
    let uploads = LockIsolated<[String]>([])
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      $0.healthReader = HealthReader { _, anchor, _ in
        HealthPage(
          mutations: anchor == nil ? [.delete("health_sample", id: "ecg-1")] : [],
          blobs: anchor == nil ? [voltages] : [], anchor: Data("1".utf8), hasMore: false)
      }
      $0.healthBlobUploader = HealthBlobUploader { sha256, _ in
        if full.value { throw HealthBatchUploader.StorageFull() }
        uploads.withValue { $0.append(sha256) }
      }
      $0.healthBatchUploader = HealthBatchUploader { _, _ in
        uploads.withValue { $0.append("batch") }
      }
      $0.healthBackfillStorage = storage
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature])
    }

    // A blob's refusal ends the run like a batch's, before any batch goes up.
    await #expect(throws: HealthBatchUploader.StorageFull.self) { try await backfill.run() }
    #expect(uploads.value.isEmpty)
    let pending = try #require(try storage.loadState()?.pending)
    #expect(pending.blobs == [sha256])
    #expect(try storage.loadFile("blob-\(sha256)") == voltages)

    full.setValue(false)
    try await backfill.run()
    #expect(uploads.value == [sha256, "batch"])
    #expect(try storage.loadFile("blob-\(sha256)") == nil)
  }

  @Test
  func blobsAreNamedAsTheServerNamesThem() {
    #expect(
      HealthBlob.sha256(Data("abc".utf8))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test
  func aResumedPageUploadsOnlyTheBlobsLeft() async throws {
    let blobs = (0..<6).map { Data("synthetic blob \($0)".utf8) }
    let refused = HealthBlob.sha256(blobs[3])
    let full = LockIsolated(true)
    let uploads = LockIsolated<[String]>([])
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      $0.healthReader = HealthReader { _, anchor, _ in
        HealthPage(
          mutations: anchor == nil ? [.delete("health_sample", id: "ecg-1")] : [],
          blobs: anchor == nil ? blobs : [], anchor: Data("1".utf8), hasMore: false)
      }
      $0.healthBlobUploader = HealthBlobUploader { sha256, _ in
        if full.value, sha256 == refused { throw HealthBatchUploader.StorageFull() }
        uploads.withValue { $0.append(sha256) }
      }
      $0.healthBatchUploader = HealthBatchUploader { _, _ in
        uploads.withValue { $0.append("batch") }
      }
      $0.healthBackfillStorage = storage
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature])
    }

    await #expect(throws: HealthBatchUploader.StorageFull.self) { try await backfill.run() }
    let left = try #require(try storage.loadState()?.pending).blobs
    #expect(left.contains(refused))
    #expect(!uploads.value.contains("batch"))

    // The next run uploads only what the page still lists, then the batch.
    full.setValue(false)
    let before = uploads.value.count
    try await backfill.run()
    let resumed = Array(uploads.value.dropFirst(before))
    #expect(Set(resumed.dropLast()) == Set(left))
    #expect(resumed.count == left.count + 1)
    #expect(resumed.last == "batch")
  }

  @Test
  func aBlobTooLargeForTheServerIsSkippedWithItsRecord() async throws {
    let tooLarge = Data(count: HealthBlob.maxBytes + 1)
    let uploads = LockIsolated<[String]>([])
    let uploadedIDs = LockIsolated<[String]>([])
    let backfill = withDependencies {
      $0.healthReader = HealthReader { _, anchor, _ in
        HealthPage(
          mutations: anchor == nil
            ? [
              .delete("health_sample", id: "route-1"),
              .upsert(
                "health_electrocardiogram", id: "ecg-1",
                row: ["voltages": .string(HealthBlob.sha256(tooLarge))]),
            ] : [],
          blobs: anchor == nil ? [tooLarge] : [], anchor: Data("1".utf8), hasMore: false)
      }
      $0.healthBlobUploader = HealthBlobUploader { sha256, _ in
        uploads.withValue { $0.append(sha256) }
      }
      $0.healthBatchUploader = HealthBatchUploader { _, file in
        uploads.withValue { $0.append("batch") }
        let lines = String(decoding: try Gzip.decompress(file), as: UTF8.self)
          .split(separator: "\n")
        for line in lines {
          let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
          let id = object?["id"] as? String ?? ""
          uploadedIDs.withValue { $0.append(id) }
        }
      }
      $0.healthBackfillStorage = .inMemory()
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature])
    }

    // Reported, and the rest of the page still goes up rather than being refused forever.
    try await withKnownIssue {
      try await backfill.run()
    } matching: { issue in
      issue.error as? HealthBlob.TooLarge == HealthBlob.TooLarge(bytes: HealthBlob.maxBytes + 1)
    }
    #expect(uploads.value == ["batch"])
    // The record that refers to it goes too, so none points at a blob that never arrives.
    #expect(uploadedIDs.value == ["route-1"])
  }

  @Test
  func aSeriesThatKeepsFailingIsSkippedAfterSomeAttempts() async throws {
    let reads = LockIsolated(0)
    let uploads = LockIsolated(0)
    let storage = HealthBackfillStorage.inMemory()
    let backfill = withDependencies {
      // A page whose series can't be read, unless the reader may skip it.
      $0.healthReader = HealthReader { type, anchor, _ in
        reads.withValue { $0 += 1 }
        guard anchor == nil else {
          return HealthPage(mutations: [], anchor: Data("1".utf8), hasMore: false)
        }
        guard type.skipsUnreadableSeries else {
          throw HealthReader.SeriesUnavailable(expected: 15360, read: 0)
        }
        return HealthPage(
          mutations: [.delete("health_sample", id: "other-1")], anchor: Data("1".utf8),
          hasMore: false)
      }
      $0.healthBatchUploader = HealthBatchUploader { _, _ in uploads.withValue { $0 += 1 } }
      $0.healthBackfillStorage = storage
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature])
    }

    // A failure might pass, so the page is read again a few times first.
    for attempt in 1...HealthBackfill.seriesAttempts {
      await #expect(throws: HealthReader.SeriesUnavailable.self) { try await backfill.run() }
      #expect(try storage.loadState()?.seriesFailures == [temperature.id: attempt])
    }
    #expect(uploads.value == 0)
    // Then the rest of the page goes up without it, and the count starts over.
    try await backfill.run()
    #expect(uploads.value == 1)
    #expect(try storage.loadState()?.seriesFailures == [:])
    #expect(try storage.loadState()?.finished == [temperature.id])
  }

  @Test
  func countsTheRecordsLeftForAnExactTotal() async throws {
    let health = FakeHealth(pages: [temperature.id: 2, sleep.id: 1])
    let server = FakeServer()
    let storage = HealthBackfillStorage.inMemory()
    // The second upload waits, so the progress can be seen mid-run.
    let (gate, open) = AsyncStream<Void>.makeStream()
    let uploads = LockIsolated(0)
    let backfill = withDependencies {
      $0.healthReader = health.reader
      $0.healthBatchUploader = HealthBatchUploader { id, file in
        if uploads.withValue({
          $0 += 1
          return $0
        }) == 2 {
          for await _ in gate { break }
        }
        try await server.uploader.upload(id, file)
      }
      // As many records as the fake has left after the anchor.
      $0.healthRecordCounter = HealthRecordCounter { type, anchor in
        let read = anchor.map { Int(String(decoding: $0, as: UTF8.self))! } ?? 0
        return ((health.pageCounts.value[type.id] ?? 0) - read) * health.perPage
      }
      $0.healthBackfillStorage = storage
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature, sleep])
    }

    let run = Task { try await backfill.run() }
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    var midRun: HealthBackfill.Progress?
    while let progress = await updates.next() {
      if progress.uploadedRecords == 3, progress.totalRecords != nil {
        midRun = progress
        break
      }
    }
    // Before the upload's done: 9 records in all, 3 of them uploaded.
    #expect(midRun?.totalRecords == 9)
    #expect(midRun?.isFinished == false)
    open.yield()
    open.finish()
    try await run.value
    #expect(await backfill.currentProgress().totalRecords == 9)
    #expect(await backfill.currentProgress().uploadedRecords == 9)
  }

  @Test
  func withoutCountingTheTotalIsUnknown() async throws {
    let health = FakeHealth(pages: [temperature.id: 1])
    let backfill = makeBackfill(
      [temperature], health: health, server: FakeServer(), storage: .inMemory())
    try await backfill.run()
    // Finished, so every type's records are known.
    #expect(await backfill.currentProgress().totalRecords == 3)

    let unfinished = makeBackfill(
      [temperature, sleep], health: FakeHealth(pages: [temperature.id: 1, sleep.id: 1]),
      server: FakeServer(), storage: .inMemory())
    #expect(await unfinished.currentProgress().totalRecords == nil)
  }

  @Test
  func pagesSavedBeforeBlobsHaveNone() throws {
    let saved = Data(
      #"{"type":"t","anchor":"MQ==","isLast":true,"batches":["b"],"records":1}"#.utf8)
    let pending = try JSONDecoder().decode(HealthBackfillState.PendingPage.self, from: saved)
    #expect(pending.blobs == [])
    #expect(pending.batches == ["b"])
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
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
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
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
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

  /// A backfill whose uploads are refused with a 60-second 429 while `limited` is set.
  private func rateLimitedBackfill(
    health: FakeHealth, server: FakeServer, storage: HealthBackfillStorage,
    limited: LockIsolated<Bool>, attempts: LockIsolated<Int>, clock: some Clock<Duration>,
    date: LockIsolated<Date>
  ) -> HealthBackfill {
    withDependencies {
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
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date = DateGenerator { date.value }
      $0.continuousClock = clock
    } operation: {
      HealthBackfill(types: [temperature, sleep])
    }
  }

  @Test
  func aRateLimitPausesSyncsOfChangesUntilItsOver() async throws {
    let health = FakeHealth(pages: [temperature.id: 1, sleep.id: 1])
    let storage = HealthBackfillStorage.inMemory()
    let (limited, attempts) = (LockIsolated(false), LockIsolated(0))
    let clock = TestClock()
    let date = LockIsolated(Date(timeIntervalSince1970: 1_760_400_000))
    let server = FakeServer()
    let backfill = rateLimitedBackfill(
      health: health, server: server, storage: storage, limited: limited, attempts: attempts,
      clock: clock, date: date)
    // A finished backfill, then new data in both types.
    try await backfill.run()
    health.pageCounts.withValue { $0 = [temperature.id: 2, sleep.id: 2] }
    attempts.setValue(0)
    limited.setValue(true)

    await #expect(throws: HealthBatchUploader.RateLimited.self) {
      try await backfill.syncChanges(of: [temperature.id, sleep.id])
    }
    // Paused, not failed, with its page kept and both types asked for again.
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await updates.next()?.failure == nil)
    #expect(try storage.loadState()?.pending != nil)
    #expect(await backfill.requestedTypes == [temperature.id, sleep.id])

    // Changes wait for the limit to pass, then go.
    try await backfill.syncChanges(of: [sleep.id])
    #expect(attempts.value == 1)
    date.withValue { $0.addTimeInterval(60) }
    try await backfill.syncChanges(of: [sleep.id])
    #expect(await backfill.requestedTypes.isEmpty)
    #expect(health.reads.value.suffix(2) == ["BodyTemperature@2", "SleepAnalysis@1"])
  }

  // A hang would block the pre-commit hook: fail instead.
  @Test(.timeLimit(.minutes(1)))
  func aRunOfEverythingWaitsOutARateLimitAndCarriesOn() async throws {
    let health = FakeHealth(pages: [temperature.id: 1, sleep.id: 1])
    let storage = HealthBackfillStorage.inMemory()
    let (limited, attempts) = (LockIsolated(true), LockIsolated(0))
    let date = LockIsolated(Date(timeIntervalSince1970: 1_760_400_000))
    let backfill = LockIsolated<HealthBackfill?>(nil)
    let runningWhileWaiting = LockIsolated<Bool?>(nil)
    // Sleeps return at once, moving the date on, so the test needn't race the run to its sleep
    // (advancing a `TestClock` before the run sleeps would leave it asleep for good).
    let clock = RecordingClock { duration in
      if let running = backfill.value {
        // Waiting, and shown as running.
        var updates = await running.progressUpdates().makeAsyncIterator()
        let progress = await updates.next()
        runningWhileWaiting.setValue(progress?.isRunning)
      }
      date.withValue { $0.addTimeInterval(TimeInterval(duration.components.seconds)) }
    }
    backfill.setValue(
      rateLimitedBackfill(
        health: health, server: FakeServer(), storage: storage, limited: limited,
        attempts: attempts, clock: clock, date: date))

    try await backfill.value?.run()
    // It waited out exactly the limit, then went on with the refused upload and the rest.
    #expect(clock.sleeps.value == [.seconds(60)])
    #expect(runningWhileWaiting.value == true)
    #expect(attempts.value == 3)
    #expect(try storage.loadState()?.finished == [temperature.id, sleep.id])
  }

  /// A backfill of temperature and sleep whose temperature uploads (or every upload, with
  /// `everything`) fail with `refusal` the first `refusals` times.
  private func refusingBackfill(
    _ refusal: any Error & Sendable, times refusals: Int, everything: Bool = false,
    server: FakeServer, storage: HealthBackfillStorage, attempts: LockIsolated<Int>,
    clock: some Clock<Duration>
  ) -> HealthBackfill {
    withDependencies {
      $0.healthReader = FakeHealth(pages: [temperature.id: 1, sleep.id: 1]).reader
      $0.healthBatchUploader = HealthBatchUploader { id, file in
        let lines = String(decoding: try Gzip.decompress(file), as: UTF8.self)
        if everything || lines.contains(temperature.id) {
          let attempt = attempts.withValue {
            $0 += 1
            return $0
          }
          if attempt <= refusals { throw refusal }
        }
        try await server.uploader.upload(id, file)
      }
      $0.healthBackfillStorage = storage
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
      $0.continuousClock = clock
    } operation: {
      HealthBackfill(types: [temperature, sleep])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func anUploadTheServerIsBusyForIsTriedAgain() async throws {
    let (server, storage, attempts) = (
      FakeServer(), HealthBackfillStorage.inMemory(), LockIsolated(0)
    )
    let clock = RecordingClock()
    let backfill = refusingBackfill(
      HealthBatchUploader.Rejected(statusCode: 503), times: 2, server: server, storage: storage,
      attempts: attempts, clock: clock)

    try await backfill.run()
    // Waited a little longer each time, then went through without failing the type.
    #expect(clock.sleeps.value == [.seconds(1), .seconds(2)])
    #expect(attempts.value == 3)
    #expect(try storage.loadState()?.finished == [temperature.id, sleep.id])
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await updates.next()?.failure == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func anUploadTheServerKeepsRefusingFailsItsTypeAfterTheRetries() async throws {
    let (server, storage, attempts) = (
      FakeServer(), HealthBackfillStorage.inMemory(), LockIsolated(0)
    )
    let clock = RecordingClock()
    let backfill = refusingBackfill(
      HealthBatchUploader.Rejected(statusCode: 503), times: .max, server: server,
      storage: storage, attempts: attempts, clock: clock)

    await #expect(throws: HealthBatchUploader.Rejected(statusCode: 503)) {
      try await backfill.run()
    }
    #expect(clock.sleeps.value == HealthBackfill.transientRetryDelays)
    #expect(attempts.value == HealthBackfill.transientRetryDelays.count + 1)
    // The other type still went up.
    #expect(try storage.loadState()?.finished == [sleep.id])
    #expect(await backfill.requestedTypes == [temperature.id])
  }

  @Test(.timeLimit(.minutes(1)))
  func anUploadThatTimesOutIsTriedAgain() async throws {
    let (server, storage, attempts) = (
      FakeServer(), HealthBackfillStorage.inMemory(), LockIsolated(0)
    )
    let clock = RecordingClock()
    let backfill = refusingBackfill(
      URLError(.timedOut), times: 1, server: server, storage: storage, attempts: attempts,
      clock: clock)

    try await backfill.run()
    #expect(clock.sleeps.value == [.seconds(1)])
    #expect(try storage.loadState()?.finished == [temperature.id, sleep.id])
  }

  // A 500 is usually the server failing on that very upload, every time.
  @Test(.timeLimit(.minutes(1)), arguments: [400, 413, 500])
  func anUploadTheServerRefusesForGoodIsntTriedAgain(statusCode: Int) async throws {
    let (server, storage, attempts) = (
      FakeServer(), HealthBackfillStorage.inMemory(), LockIsolated(0)
    )
    let clock = RecordingClock()
    let backfill = refusingBackfill(
      HealthBatchUploader.Rejected(statusCode: statusCode), times: 1, server: server,
      storage: storage, attempts: attempts, clock: clock)

    await #expect(throws: HealthBatchUploader.Rejected(statusCode: statusCode)) {
      try await backfill.run()
    }
    #expect(clock.sleeps.value.isEmpty)
    #expect(attempts.value == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func aServerThatsDownIsWaitedOutOncePerRun() async throws {
    let (server, storage, attempts) = (
      FakeServer(), HealthBackfillStorage.inMemory(), LockIsolated(0)
    )
    let clock = RecordingClock()
    let backfill = refusingBackfill(
      HealthBatchUploader.Rejected(statusCode: 503), times: .max, everything: true,
      server: server, storage: storage, attempts: attempts, clock: clock)

    await #expect(throws: HealthBatchUploader.Rejected(statusCode: 503)) {
      try await backfill.run()
    }
    // The first upload waited the retries out; the second type's failed at once.
    #expect(clock.sleeps.value == HealthBackfill.transientRetryDelays)
    #expect(attempts.value == HealthBackfill.transientRetryDelays.count + 2)
    #expect(try storage.loadState()?.finished == [])

    // The next run waits again.
    await #expect(throws: HealthBatchUploader.Rejected(statusCode: 503)) {
      try await backfill.run()
    }
    #expect(clock.sleeps.value.count == 2 * HealthBackfill.transientRetryDelays.count)
  }

  @Test(.timeLimit(.minutes(1)))
  func aBlobTheServerIsBusyForIsTriedAgain() async throws {
    let voltages = Data((0..<1000).map { UInt8($0 % 251) })
    let busy = LockIsolated(1)
    let uploads = LockIsolated<[String]>([])
    let clock = RecordingClock()
    let backfill = withDependencies {
      $0.healthReader = HealthReader { _, anchor, _ in
        HealthPage(
          mutations: anchor == nil ? [.delete("health_sample", id: "ecg-1")] : [],
          blobs: anchor == nil ? [voltages] : [], anchor: Data("1".utf8), hasMore: false)
      }
      $0.healthBlobUploader = HealthBlobUploader { sha256, _ in
        if busy.withValue({
          $0 -= 1
          return $0 >= 0
        }) {
          throw HealthBatchUploader.Rejected(statusCode: 502)
        }
        uploads.withValue { $0.append(sha256) }
      }
      $0.healthBatchUploader = HealthBatchUploader { _, _ in
        uploads.withValue { $0.append("batch") }
      }
      $0.healthBackfillStorage = .inMemory()
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
      $0.continuousClock = clock
    } operation: {
      HealthBackfill(types: [temperature])
    }

    try await backfill.run()
    #expect(clock.sleeps.value == [.seconds(1)])
    #expect(uploads.value == [HealthBlob.sha256(voltages), "batch"])
  }

  @Test
  func uploadsCharacteristicsWhenTheyChange() async throws {
    let server = FakeServer()
    let blood = LockIsolated<JSONValue>("aPositive")
    let backfill = withDependencies {
      $0.healthReader = FakeHealth(pages: [:]).reader
      $0.healthBatchUploader = server.uploader
      $0.healthBackfillStorage = .inMemory()
      $0.healthCharacteristicsReader = HealthCharacteristicsReader {
        // Read in a different order each time: only the values count.
        [
          HealthEncoder.characteristic(.bloodType, value: blood.value),
          HealthEncoder.characteristic(.biologicalSex, value: "female"),
        ].shuffled()
      }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [temperature])
    }

    try await backfill.run()
    #expect(
      server.records.value.isSuperset(of: [
        "HKCharacteristicTypeIdentifierBloodType", "HKCharacteristicTypeIdentifierBiologicalSex",
      ]))
    let uploads = server.accepted.value.count
    try await backfill.run()
    #expect(server.accepted.value.count == uploads)

    blood.setValue("oNegative")
    try await backfill.run()
    #expect(server.accepted.value.count == uploads + 1)
  }

  @Test
  func deletesACharacteristicThatStopsBeingReadable() async throws {
    let server = FakeServer()
    let readable = LockIsolated(true)
    let lines = LockIsolated<[String]>([])
    let backfill = withDependencies {
      $0.healthReader = FakeHealth(pages: [:]).reader
      $0.healthBatchUploader = HealthBatchUploader { id, file in
        let text = String(decoding: try Gzip.decompress(file), as: UTF8.self)
        lines.withValue { $0 += text.split(separator: "\n").map(String.init) }
        try await server.uploader.upload(id, file)
      }
      $0.healthBackfillStorage = .inMemory()
      $0.healthCharacteristicsReader = HealthCharacteristicsReader {
        [HealthEncoder.characteristic(.biologicalSex, value: "female")]
          + (readable.value
            ? [HealthEncoder.characteristic(.dateOfBirth, value: .object(["year": 1990]))] : [])
      }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [])
    }
    try await backfill.run()
    // Read access to date of birth was turned off.
    readable.setValue(false)
    lines.setValue([])
    try await backfill.run()
    #expect(lines.value.contains { $0.contains(#""op":"delete""#) && $0.contains("DateOfBirth") })
    #expect(!lines.value.contains { $0.contains("BiologicalSex") && $0.contains("delete") })
  }

  @Test
  func aLockedPhoneDoesntLookLikeRemovedCharacteristics() async throws {
    let server = FakeServer()
    let locked = LockIsolated(false)
    let backfill = withDependencies {
      $0.healthReader = FakeHealth(pages: [:]).reader
      $0.healthBatchUploader = server.uploader
      $0.healthBackfillStorage = .inMemory()
      $0.healthCharacteristicsReader = HealthCharacteristicsReader {
        if locked.value { throw HealthReader.Locked() }
        return [HealthEncoder.characteristic(.bloodType, value: "aPositive")]
      }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [])
    }
    try await backfill.run()
    let uploads = server.accepted.value.count
    locked.setValue(true)
    await #expect(throws: HealthReader.Locked.self) { try await backfill.run() }
    locked.setValue(false)
    // Unchanged once it's unlocked, so nothing goes up again.
    try await backfill.run()
    #expect(server.accepted.value.count == uploads)
  }

  @Test
  func uploadsAllActivitySummariesOnceThenTheLastWeek() async throws {
    let server = FakeServer()
    let date = LockIsolated(Date(timeIntervalSince1970: 1_760_400_000))
    let reads = LockIsolated<[Date?]>([])
    let health = FakeHealth(pages: [temperature.id: 1])
    let backfill = withDependencies {
      $0.healthReader = health.reader
      $0.healthBatchUploader = server.uploader
      $0.healthBackfillStorage = .inMemory()
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { from in
        reads.withValue { $0.append(from) }
        return [
          .upsert(HealthEncoder.activitySummaryEntity, id: "2025-10-14", row: ["paused": false])
        ]
      }
      $0.uuid = .incrementing
      $0.date = DateGenerator { date.value }
    } operation: {
      HealthBackfill(types: [temperature])
    }

    try await backfill.run()
    #expect(server.records.value.contains("2025-10-14"))
    date.withValue { $0.addTimeInterval(24 * 60 * 60) }
    try await backfill.run()
    // Syncing changes alone doesn't read them.
    health.pageCounts.withValue { $0[temperature.id] = 2 }
    try await backfill.syncChanges(of: [temperature.id])
    #expect(
      reads.value == [
        nil,
        Date(timeIntervalSince1970: 1_760_400_000 - HealthBackfill.activitySummaryWindow),
      ])
  }

  @Test
  func aFailedExtraIsTriedAgainNextRun() async throws {
    struct Unavailable: Error {}
    let failing = LockIsolated(true)
    let server = FakeServer()
    let backfill = withDependencies {
      $0.healthReader = FakeHealth(pages: [:]).reader
      $0.healthBatchUploader = server.uploader
      $0.healthBackfillStorage = .inMemory()
      $0.healthCharacteristicsReader = HealthCharacteristicsReader {
        if failing.value { throw Unavailable() }
        return [HealthEncoder.characteristic(.bloodType, value: "aPositive")]
      }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
    } operation: {
      HealthBackfill(types: [])
    }
    await withKnownIssue {
      try await backfill.run()
    }
    #expect(server.records.value.isEmpty)
    failing.setValue(false)
    try await backfill.run()
    #expect(server.records.value == ["HKCharacteristicTypeIdentifierBloodType"])
  }

  @Test
  func networkFailuresAreOffline() {
    #expect(HealthBackfill.isOffline(URLError(.notConnectedToInternet)))
    #expect(!HealthBackfill.isOffline(HealthBatchUploader.Rejected(statusCode: 503)))
    // A slow server isn't the phone being offline.
    #expect(!HealthBackfill.isOffline(URLError(.timedOut)))
  }
}

/// An immediate clock that records how long each sleep was for, and runs `onSleep` during it.
/// Not `ImmediateClock` itself: its sleeps wait on background-priority tasks, which tests that
/// spin waiting for a state can starve when they run alongside.
private final class RecordingClock: Clock, Sendable {
  typealias Instant = ImmediateClock<Duration>.Instant

  private let onSleep: @Sendable (Duration) async -> Void
  private let current = LockIsolated(Instant())
  let sleeps = LockIsolated<[Duration]>([])

  init(onSleep: @escaping @Sendable (Duration) async -> Void = { _ in }) {
    self.onSleep = onSleep
  }

  var now: Instant { current.value }
  var minimumResolution: Duration { .zero }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let duration = now.duration(to: deadline)
    sleeps.withValue { $0.append(duration) }
    await onSleep(duration)
    try Task.checkCancellation()
    current.withValue { $0 = max($0, deadline) }
    await Task.yield()
  }
}
