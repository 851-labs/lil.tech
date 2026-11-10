import Dependencies
import Foundation
import LilGzip
import Testing

@testable import HealthUpload

// Records that don't go up (851-4151): those that can't be encoded, are too long for the server,
// or that the server refuses or fails are held back, counted and tried again, rather than dropped
// as the anchor moves past them. Synthetic data only (AGENTS.md).

/// A discrete type, so no sums are uploaded.
private let temperature = HealthBackfillType(id: "HKQuantityTypeIdentifierBodyTemperature")

/// A fake HealthKit: a log of records added and deleted, read `perPage` events at a time, the
/// anchor being how many were read.
private final class FakeRecords: Sendable {
  enum Event: Sendable {
    case added(String)
    case deleted(String)
  }

  let log: LockIsolated<[Event]>
  /// Records the encoder can't encode, and those whose line is over 1 MB.
  let unreadable = LockIsolated<Set<String>>([])
  let tooLong = LockIsolated<Set<String>>([])
  /// Records that are quantity series (851-4149): they go up with their values' records.
  let series = LockIsolated<Set<String>>([])
  let perPage: Int
  /// The anchor each page read started from, and the IDs each lookup asked for.
  let reads = LockIsolated<[Int?]>([])
  let lookups = LockIsolated<[[String]]>([])
  /// Whether each lookup skipped series that can't be read, rather than failing on them.
  let lookupsSkipSeries = LockIsolated<[Bool]>([])
  /// What `series`' records are: a quantity series' values, or a workout's or ECG's links
  /// (851-4153).
  let dependent: String

  init(
    _ ids: [String], perPage: Int = 10, dependent: String = HealthEncoder.quantitySeriesEntity
  ) {
    log = LockIsolated(ids.map(Event.added))
    self.perPage = perPage
    self.dependent = dependent
  }

  func encode(_ ids: [String]) -> HealthPage {
    var page = HealthPage(mutations: [], anchor: Data(), hasMore: false)
    for id in ids {
      if unreadable.value.contains(id) {
        page.failed.append(id)
        continue
      }
      let padding = tooLong.value.contains(id) ? HealthBatchWriter.maxLineBytes : 0
      page.mutations.append(
        .upsert(
          HealthEncoder.sampleEntity, id: id,
          row: [
            "type": .string(temperature.id),
            "note": .string(String(repeating: "x", count: padding)),
          ]))
      if series.value.contains(id) { page.mutations.append(seriesRecord(id)) }
    }
    return page
  }

  func seriesRecord(_ id: String) -> HealthMutation {
    .upsert(dependent, id: id, row: ["count": 2])
  }

  var reader: HealthReader {
    HealthReader(
      page: { [self] type, anchor, _ in
        let from = anchor.map { Int(String(decoding: $0, as: UTF8.self))! }
        reads.withValue { $0.append(from) }
        let events = log.value
        let start = min(from ?? 0, events.count)
        let end = min(events.count, start + perPage)
        let deleted = Set(events.compactMap { if case .deleted(let id) = $0 { id } else { nil } })
        var added: [String] = []
        var deletions: [HealthMutation] = []
        for event in events[start..<end] {
          switch event {
          // From the start, only what's still there, as HealthKit reads it.
          case .added(let id) where from != nil || !deleted.contains(id): added.append(id)
          case .added: break
          case .deleted(let id):
            if from != nil { deletions.append(.delete(type.entity, id: id)) }
          }
        }
        var page = encode(added)
        page.mutations += deletions
        page.anchor = Data(String(end).utf8)
        page.hasMore = end < events.count
        return page
      },
      records: { [self] type, ids in
        lookups.withValue { $0.append(ids) }
        lookupsSkipSeries.withValue { $0.append(type.skipsUnreadableSeries) }
        let deleted = Set(
          log.value.compactMap { if case .deleted(let id) = $0 { id } else { nil } })
        let present = Set(
          log.value.compactMap { if case .added(let id) = $0 { id } else { nil } })
        return encode(ids.filter { present.contains($0) && !deleted.contains($0) })
      },
      series: { [self] _, _, _ in
        // Every series still there, as their values' records alone.
        let deleted = Set(
          log.value.compactMap { if case .deleted(let id) = $0 { id } else { nil } })
        let ids = log.value.compactMap { if case .added(let id) = $0 { id } else { nil } }
          .filter { series.value.contains($0) && !deleted.contains($0) }
        return HealthPage(mutations: ids.map(seriesRecord), anchor: Data("s".utf8), hasMore: false)
      })
  }
}

/// A fake server: keeps each accepted batch's record IDs, and answers for them as `status` says.
private final class FakeBatches: Sendable {
  /// Each accepted batch's record IDs (not its provenance records), in order, and whether it
  /// failed.
  let batches = LockIsolated<[(id: String, records: [String], failed: Bool)]>([])
  /// Records the server refuses, and whether it names them. A series' values are `series:<id>`
  /// in `batches`, and `refusedSeries` refuses them by their sample's ID.
  let refused = LockIsolated<Set<String>>([])
  let refusedSeries = LockIsolated<Set<String>>([])
  let namesRefused = LockIsolated(true)
  /// Batches it fails whole, by a record in them when they're uploaded, and whether every batch
  /// is still queued.
  let failsWith = LockIsolated<Set<String>>([])
  let queued = LockIsolated(false)
  let checks = LockIsolated<[[String]]>([])
  /// The entity `refusedSeries` names.
  let dependent: String

  init(dependent: String = HealthEncoder.quantitySeriesEntity) {
    self.dependent = dependent
  }

  var uploaded: [String] { batches.value.flatMap(\.records) }

  var uploader: HealthBatchUploader {
    HealthBatchUploader { [self] id, file in
      let ids = String(decoding: try Gzip.decompress(file), as: UTF8.self)
        .split(separator: "\n")
        .compactMap { line -> String? in
          let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
          guard object?["entity"] as? String != "health_provenance" else { return nil }
          if HealthEncoder.dependentEntities.contains(object?["entity"] as? String ?? "") {
            return (object?["id"] as? String).map { "series:\($0)" }
          }
          return object?["id"] as? String
        }
      let failed = !failsWith.value.isDisjoint(with: ids)
      batches.withValue { $0.append((id, ids, failed)) }
    }
  }

  var statusReader: HealthBatchStatusReader {
    HealthBatchStatusReader { [self] ids in
      checks.withValue { $0.append(ids) }
      return ids.compactMap { id in
        guard let batch = batches.value.first(where: { $0.id == id }) else { return nil }
        let records = batch.records
        if queued.value { return HealthBatchStatus(id: id, status: "queued") }
        if batch.failed {
          return HealthBatchStatus(id: id, status: "failed", failure: "The batch timed out")
        }
        let refusedHere = records.filter(refused.value.contains)
        let refusedSeriesHere = refusedSeries.value.filter { records.contains("series:\($0)") }
        return HealthBatchStatus(
          id: id, status: "applied", rejected: refusedHere.count + refusedSeriesHere.count,
          rejectedLines: refusedHere.map {
            namesRefused.value
              ? .init(entity: HealthEncoder.sampleEntity, id: $0) : .init(entity: nil, id: nil)
          }
            + refusedSeriesHere.sorted().map {
              .init(entity: dependent, id: $0)
            })
      }
    }
  }
}

private func makeBackfill(
  health: FakeRecords, server: FakeBatches, storage: HealthBackfillStorage,
  build: String = "1.0 (1)", statusReader: HealthBatchStatusReader? = nil,
  type: HealthBackfillType = temperature
) -> HealthBackfill {
  withDependencies {
    $0.healthReader = health.reader
    $0.healthBatchUploader = server.uploader
    $0.healthBatchStatusReader = statusReader ?? server.statusReader
    $0.healthBackfillStorage = storage
    $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
    $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
    $0.uuid = .incrementing
    $0.date.now = Date(timeIntervalSince1970: 1_760_400_000)
  } operation: {
    HealthBackfill(types: [type], build: build)
  }
}

struct HeldBackTests {
  /// A series whose values the server refuses, though it took its sample (851-4149), is held back
  /// and no longer counted, then counted once when it goes up whole.
  @Test
  func aSeriesTheServerRefusesIsHeldBackAndCountedOnce() async throws {
    let health = FakeRecords(["a", "b"])
    health.series.setValue(["b"])
    let server = FakeBatches()
    server.refusedSeries.setValue(["b"])
    let storage = HealthBackfillStorage.inMemory()
    try await makeBackfill(health: health, server: server, storage: storage).run()
    #expect(server.uploaded == ["a", "b", "series:b"])
    // Its values don't count as a record.
    #expect(try storage.loadState()?.uploadedRecords == 2)

    // The next run hears it was refused.
    try await makeBackfill(health: health, server: server, storage: storage).run()
    var state = try #require(try storage.loadState())
    #expect(state.heldBack[temperature.id]?.records["b"]?.reason == .refused)
    #expect(state.uploadedRecords == 1)

    // A newer build sends it again, sample and values, counted once.
    server.refusedSeries.setValue([])
    let updated = makeBackfill(health: health, server: server, storage: storage, build: "1.1 (2)")
    try await updated.run()
    try await updated.run()
    #expect(server.uploaded == ["a", "b", "series:b", "b", "series:b"])
    state = try #require(try storage.loadState())
    #expect(state.heldBack == [:])
    #expect(state.uploadedRecords == 2)
  }

  /// A workout whose samples' record the server refuses, though it took the workout (851-4153),
  /// is held back as a series is, and goes up again whole, counted once.
  @Test
  func aWorkoutWhoseLinksTheServerRefusesIsHeldBackAndCountedOnce() async throws {
    let workouts = HealthBackfillType(id: "HKWorkoutTypeIdentifier")
    let health = FakeRecords(["a", "b"], dependent: HealthEncoder.workoutSamplesEntity)
    health.series.setValue(["a", "b"])
    let server = FakeBatches(dependent: HealthEncoder.workoutSamplesEntity)
    server.refusedSeries.setValue(["b"])
    let storage = HealthBackfillStorage.inMemory()
    func backfill(_ build: String = "1.0 (1)") -> HealthBackfill {
      makeBackfill(health: health, server: server, storage: storage, build: build, type: workouts)
    }
    try await backfill().run()
    #expect(server.uploaded == ["a", "series:a", "b", "series:b"])
    #expect(try storage.loadState()?.uploadedRecords == 2)

    try await backfill().run()
    var state = try #require(try storage.loadState())
    #expect(state.heldBack[workouts.id]?.records["b"]?.reason == .refused)
    #expect(state.uploadedRecords == 1)

    server.refusedSeries.setValue([])
    let updated = backfill("1.1 (2)")
    try await updated.run()
    try await updated.run()
    #expect(server.uploaded.suffix(2) == ["b", "series:b"])
    state = try #require(try storage.loadState())
    #expect(state.heldBack == [:])
    #expect(state.uploadedRecords == 2)
  }

  /// Series read again whose batch fails (851-4149) are held back and tried again by ID, and the
  /// counts end where they were.
  @Test
  func seriesReadAgainWhoseBatchFailsAreTriedAgain() async throws {
    let health = FakeRecords(["a", "b"])
    health.series.setValue(["b"])
    let server = FakeBatches()
    let storage = HealthBackfillStorage.inMemory()
    // One backfill throughout, so batch IDs don't repeat.
    let backfill = makeBackfill(health: health, server: server, storage: storage)
    try await backfill.run()
    // Read by an earlier release.
    var state = try #require(try storage.loadState())
    state.dependentsEncodings = [:]
    try storage.saveState(state)

    server.failsWith.setValue(["series:b"])
    try await backfill.run()
    #expect(server.uploaded == ["a", "b", "series:b", "series:b"])
    #expect(try storage.loadState()?.uploadedRecords == 2)

    // The next run hears it failed, holds it back and sends it again, whole.
    server.failsWith.setValue([])
    try await backfill.run()
    #expect(health.lookups.value == [["b"]])
    #expect(server.uploaded == ["a", "b", "series:b", "series:b", "b", "series:b"])
    state = try #require(try storage.loadState())
    #expect(state.heldBack == [:])
    #expect(state.uploadedRecords == 2)
    #expect(state.dependentsEncodings[temperature.id] == HealthEncoder.quantitySeriesEncoding)
  }

  /// A record held back isn't let go by its series going up alone when series are read again.
  @Test
  func seriesReadAgainLeaveRecordsHeldBackAlone() async throws {
    let health = FakeRecords(["a", "huge"])
    health.series.setValue(["a", "huge"])
    health.tooLong.setValue(["huge"])
    let server = FakeBatches()
    let storage = HealthBackfillStorage.inMemory()
    try await makeBackfill(health: health, server: server, storage: storage).run()
    var state = try #require(try storage.loadState())
    #expect(state.heldBack[temperature.id]?.records["huge"]?.reason == .tooLarge)
    state.dependentsEncodings = [:]
    try storage.saveState(state)

    try await makeBackfill(health: health, server: server, storage: storage).run()
    #expect(
      server.uploaded.filter { $0.hasPrefix("series:") } == ["series:a", "series:huge", "series:a"])
    state = try #require(try storage.loadState())
    #expect(state.heldBack[temperature.id]?.records["huge"]?.reason == .tooLarge)
    #expect(state.uploadedRecords == 1)
  }

  @Test
  func aRecordThatCantBeEncodedIsHeldBackAndTriedEveryRun() async throws {
    let health = FakeRecords(["a", "b", "c"])
    health.unreadable.setValue(["b"])
    let server = FakeBatches()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(health: health, server: server, storage: storage)

    // The rest goes up, and the type is done: one record can't hold it up.
    try await backfill.run()
    #expect(server.uploaded == ["a", "c"])
    var progress = await backfill.currentProgress()
    #expect(progress.heldBack == [temperature.id: 1])
    #expect(progress.uploadedRecords == 2)
    #expect(progress.isFinished)
    #expect(try storage.loadState()?.heldBack[temperature.id]?.records["b"]?.reason == .unreadable)

    // Tried again by ID each run of everything, until it can be read.
    try await backfill.run()
    #expect(health.lookups.value == [["b"]])
    #expect(server.uploaded == ["a", "c"])
    health.unreadable.setValue([])
    try await backfill.run()
    #expect(health.lookups.value == [["b"], ["b"]])
    // A series that still can't be read is held back again, not a failure of the type.
    #expect(health.lookupsSkipSeries.value == [true, true])
    #expect(server.uploaded == ["a", "c", "b"])
    progress = await backfill.currentProgress()
    #expect(progress.heldBack == [:])
    #expect(progress.uploadedRecords == 3)
    // The anchor didn't move: the next page starts where it was.
    #expect(try storage.loadState()?.anchors[temperature.id] == Data("3".utf8))
  }

  @Test
  func aRecordTooLongIsHeldBackAndTriedAgainOnceTheAppIsUpdated() async throws {
    let health = FakeRecords(["a", "huge"])
    health.tooLong.setValue(["huge"])
    let server = FakeBatches()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(health: health, server: server, storage: storage)

    try await backfill.run()
    #expect(server.uploaded == ["a"])
    #expect(await backfill.currentProgress().heldBack == [temperature.id: 1])
    #expect(await backfill.currentProgress().uploadedRecords == 1)
    #expect(try storage.loadState()?.heldBack[temperature.id]?.records["huge"]?.reason == .tooLarge)

    // The same build would send the same line.
    try await backfill.run()
    #expect(health.lookups.value.isEmpty)

    // A newer one may fit it.
    health.tooLong.setValue([])
    let updated = makeBackfill(health: health, server: server, storage: storage, build: "1.1 (2)")
    try await updated.run()
    #expect(health.lookups.value == [["huge"]])
    #expect(server.uploaded == ["a", "huge"])
    #expect(await updated.currentProgress().heldBack == [:])
  }

  @Test
  func recordsTheServerRefusesAreHeldBackAndTriedAgainOnceTheAppIsUpdated() async throws {
    let health = FakeRecords(["a", "b", "c"])
    let server = FakeBatches()
    server.refused.setValue(["b"])
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(health: health, server: server, storage: storage)

    // Accepted, so counted, until the server is asked how its batches went: the next run.
    try await backfill.run()
    #expect(server.uploaded == ["a", "b", "c"])
    #expect(await backfill.currentProgress().uploadedRecords == 3)
    #expect(try storage.loadState()?.uploaded.count == 1)

    try await backfill.run()
    #expect(server.checks.value.count == 1)
    var progress = await backfill.currentProgress()
    #expect(progress.heldBack == [temperature.id: 1])
    #expect(progress.uploadedRecords == 2)
    #expect(try storage.loadState()?.uploaded == [])
    #expect(try storage.loadState()?.heldBack[temperature.id]?.records["b"]?.reason == .refused)
    // Not again with the same build.
    #expect(health.lookups.value.isEmpty)

    server.refused.setValue([])
    let updated = makeBackfill(health: health, server: server, storage: storage, build: "1.1 (2)")
    try await updated.run()
    #expect(health.lookups.value == [["b"]])
    #expect(server.uploaded == ["a", "b", "c", "b"])
    // Checked like any page: this time it applied.
    try await updated.run()
    progress = await updated.currentProgress()
    #expect(progress.heldBack == [:])
    #expect(progress.uploadedRecords == 3)
    #expect(try storage.loadState()?.uploaded == [])
  }

  @Test
  func refusalsTheServerDoesntNameAreReadAgainFromTheStartOnceTheAppIsUpdated() async throws {
    let health = FakeRecords(["a", "b", "c"])
    let server = FakeBatches()
    server.refused.setValue(["b", "c"])
    server.namesRefused.setValue(false)
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(health: health, server: server, storage: storage)

    try await backfill.run()
    try await backfill.run()
    #expect(await backfill.currentProgress().heldBack == [temperature.id: 2])
    #expect(await backfill.currentProgress().uploadedRecords == 1)
    #expect(health.reads.value == [nil, 3])

    // Not known by ID, so the whole type goes again.
    server.refused.setValue([])
    let updated = makeBackfill(health: health, server: server, storage: storage, build: "1.1 (2)")
    try await updated.run()
    #expect(health.reads.value.last == .some(nil))
    #expect(server.uploaded == ["a", "b", "c", "a", "b", "c"])
    #expect(await updated.currentProgress().heldBack == [:])
    #expect(await updated.currentProgress().uploadedRecords == 3)
  }

  @Test
  func aBatchTheServerFailsSendsItsPageAgain() async throws {
    let health = FakeRecords(["a", "b", "c", "d"], perPage: 2)
    let server = FakeBatches()
    server.failsWith.setValue(["c"])
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(health: health, server: server, storage: storage)

    try await backfill.run()
    #expect(server.uploaded == ["a", "b", "c", "d"])
    #expect(health.reads.value == [nil, 2])

    // The type goes back to the anchor its page was read from, and that page goes again.
    server.failsWith.setValue([])
    try await backfill.run()
    #expect(health.reads.value == [nil, 2, 2])
    #expect(server.uploaded == ["a", "b", "c", "d", "c", "d"])
    #expect(await backfill.currentProgress().uploadedRecords == 4)
    #expect(await backfill.currentProgress().isFinished)
    try await backfill.run()
    #expect(try storage.loadState()?.uploaded == [])
  }

  @Test
  func aFailedBatchOfRecordsSentAgainHoldsThemBackAgain() async throws {
    let health = FakeRecords(["a", "b"])
    health.unreadable.setValue(["b"])
    let server = FakeBatches()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(health: health, server: server, storage: storage)
    try await backfill.run()

    health.unreadable.setValue([])
    server.failsWith.setValue(["b"])
    try await backfill.run()
    #expect(server.uploaded == ["a", "b"])
    #expect(await backfill.currentProgress().heldBack == [:])

    // Its page wasn't read from an anchor, so the next run's check holds it back again, and
    // the run tries it.
    server.failsWith.setValue([])
    try await backfill.run()
    #expect(health.lookups.value == [["b"], ["b"]])
    #expect(server.uploaded == ["a", "b", "b"])
    #expect(await backfill.currentProgress().heldBack == [:])
    try await backfill.run()
    #expect(try storage.loadState()?.uploaded == [])
    #expect(await backfill.currentProgress().uploadedRecords == 2)
  }

  @Test
  func batchesStillQueuedAreCheckedLater() async throws {
    let health = FakeRecords(["a", "b"])
    let server = FakeBatches()
    server.queued.setValue(true)
    server.refused.setValue(["b"])
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(health: health, server: server, storage: storage)

    try await backfill.run()
    try await backfill.run()
    #expect(server.checks.value.count == 1)
    #expect(try storage.loadState()?.uploaded.map(\.batches.count) == [1])
    #expect(await backfill.currentProgress().heldBack == [:])

    server.queued.setValue(false)
    try await backfill.run()
    #expect(await backfill.currentProgress().heldBack == [temperature.id: 1])
    #expect(try storage.loadState()?.uploaded == [])
  }

  @Test
  func batchesThatCantBeCheckedWaitForTheNextRun() async throws {
    let health = FakeRecords(["a"])
    let server = FakeBatches()
    let storage = HealthBackfillStorage.inMemory()
    let offline = LockIsolated(true)
    let backfill = makeBackfill(
      health: health, server: server, storage: storage,
      statusReader: HealthBatchStatusReader { ids in
        if offline.value { throw URLError(.notConnectedToInternet) }
        return try await server.statusReader.statuses(ids)
      })

    try await backfill.run()
    // Not a failure of the run.
    try await backfill.run()
    #expect(await backfill.currentProgress().failure == nil)
    #expect(try storage.loadState()?.uploaded.count == 1)
    offline.setValue(false)
    try await backfill.run()
    #expect(try storage.loadState()?.uploaded == [])
  }

  @Test
  func aHeldBackRecordDeletedFromHealthIsLetGo() async throws {
    let health = FakeRecords(["a", "b", "c"])
    health.tooLong.setValue(["b", "c"])
    let server = FakeBatches()
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(health: health, server: server, storage: storage)
    try await backfill.run()
    #expect(await backfill.currentProgress().heldBack == [temperature.id: 2])

    // Its deletion comes through the anchor.
    health.log.withValue { $0.append(.deleted("b")) }
    try await backfill.syncChanges(of: [temperature.id])
    #expect(await backfill.currentProgress().heldBack == [temperature.id: 1])

    // One Health no longer has when it's looked up goes too.
    health.log.withValue { $0 = $0.filter { if case .added("c") = $0 { false } else { true } } }
    let updated = makeBackfill(health: health, server: server, storage: storage, build: "1.1 (2)")
    try await updated.run()
    #expect(health.lookups.value == [["c"]])
    #expect(await updated.currentProgress().heldBack == [:])
    // Its deletion goes up, in case the server has it (a deletion it refused).
    #expect(server.uploaded.last == "c")
  }

  @Test
  func aHeldBackRecordThatGoesUpInAPageReadAgainIsLetGo() async throws {
    let health = FakeRecords(["a", "b", "c", "d"], perPage: 2)
    health.tooLong.setValue(["c"])
    let server = FakeBatches()
    server.failsWith.setValue(["d"])
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(health: health, server: server, storage: storage)
    try await backfill.run()
    #expect(await backfill.currentProgress().heldBack == [temperature.id: 1])

    // The failed batch sends its page again from its anchor, and now "c" fits.
    health.tooLong.setValue([])
    server.failsWith.setValue([])
    try await backfill.run()
    #expect(server.uploaded == ["a", "b", "d", "c", "d"])
    #expect(health.lookups.value.isEmpty)
    #expect(await backfill.currentProgress().heldBack == [:])
    #expect(await backfill.currentProgress().uploadedRecords == 4)
  }

  @Test
  func aRefusedSampleOfACorrelationReadsItsTypeAgainOnceTheAppIsUpdated() async throws {
    let bloodPressure = HealthBackfillType(
      id: "HKCorrelationTypeIdentifierBloodPressure", isCorrelation: true)
    let health = FakeRecords(["a", "b"])
    let server = FakeBatches()
    server.refused.setValue(["b"])
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(
      health: health, server: server, storage: storage, type: bloodPressure)
    try await backfill.run()
    try await backfill.run()
    // It's read with its correlation, so it can't be looked up by its own ID.
    #expect(await backfill.currentProgress().heldBack == [bloodPressure.id: 1])
    #expect(try storage.loadState()?.heldBack[bloodPressure.id]?.unnamed == 1)

    server.refused.setValue([])
    let updated = makeBackfill(
      health: health, server: server, storage: storage, build: "1.1 (2)", type: bloodPressure)
    try await updated.run()
    #expect(health.lookups.value.isEmpty)
    #expect(health.reads.value.last == .some(nil))
    #expect(await updated.currentProgress().heldBack == [:])
  }

  @Test
  func heldBackStateFromBeforeItsDecodes() throws {
    let state = try JSONDecoder().decode(
      HealthBackfillState.self, from: Data(#"{"anchors": {}, "finished": []}"#.utf8))
    #expect(state.heldBack == [:])
    #expect(state.uploaded == [])
    let page = try JSONDecoder().decode(
      HealthBackfillState.PendingPage.self,
      from: Data(
        #"{"type": "t", "anchor": "MQ==", "isLast": true, "batches": ["b"], "records": 1}"#.utf8))
    // Not known, so a failed batch of it can't send it again.
    #expect(page.from == nil)
    #expect(page.retried == nil)
  }
}
