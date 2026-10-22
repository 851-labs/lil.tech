import Dependencies
import Foundation
import LilGzip
import Testing

@testable import HealthUpload

// Synthetic data only (AGENTS.md).
private let steps = HealthBackfillType(id: "HKQuantityTypeIdentifierStepCount")
private let now = Date(timeIntervalSince1970: 1_760_486_400)  // 2025-10-15 00:00 UTC

/// An uploaded line, with the fields these tests look at.
private struct Line: Decodable, Sendable {
  struct Row: Decodable, Sendable {
    var sum: Double?
    var unit: String?
    var bucketStart: Int?
    var pairedWithWatch: Bool?
  }

  var entity: String
  var id: String
  var row: Row?
}

/// Uploaded lines, decoded.
private final class Uploads: Sendable {
  let lines = LockIsolated<[Line]>([])
  /// Fails uploads of sums after this many succeeded, if set.
  let failSumsAfter = LockIsolated<Int?>(nil)
  let sumUploads = LockIsolated(0)

  struct Offline: Error {}

  var uploader: HealthBatchUploader {
    HealthBatchUploader { [self] _, file in
      let text = String(decoding: try Gzip.decompress(file), as: UTF8.self)
      if text.contains(#""entity":"health_statistic""#) {
        let count = sumUploads.withValue {
          $0 += 1
          return $0
        }
        if let limit = failSumsAfter.value, count > limit { throw Offline() }
      }
      for line in text.split(separator: "\n") {
        let decoded = try JSONDecoder().decode(Line.self, from: Data(line.utf8))
        lines.withValue { $0.append(decoded) }
      }
    }
  }

  func ids(_ entity: String) -> [String] {
    lines.value.filter { $0.entity == entity }.map(\.id)
  }

  func rows(_ entity: String) -> [Line.Row] {
    lines.value.filter { $0.entity == entity }.compactMap(\.row)
  }
}

/// A page of step samples starting at `starts`, or deletions.
private func page(starts: [Date] = [], deletions: Int = 0) -> HealthPage {
  let upserts = starts.enumerated().map { n, start in
    HealthMutation.upsert(
      "health_sample", id: "sample-\(n)",
      row: ["startDate": .number(start.timeIntervalSince1970 * 1000)])
  }
  let deletes = (0..<deletions).map { HealthMutation.delete("health_sample", id: "deleted-\($0)") }
  return HealthPage(mutations: upserts + deletes, anchor: Data("1".utf8), hasMore: false)
}

private func makeBackfill(
  _ types: [HealthBackfillType] = [steps], pages: LockIsolated<[HealthPage]>,
  buckets: [HealthBucket], uploads: Uploads, storage: HealthBackfillStorage = .inMemory(),
  asked: LockIsolated<[DateInterval]>
) -> HealthBackfill {
  withDependencies {
    $0.healthReader = HealthReader { _, _, _ in
      pages.withValue {
        $0.isEmpty
          ? HealthPage(mutations: [], anchor: Data("1".utf8), hasMore: false) : $0.removeFirst()
      }
    }
    $0.healthStatisticsReader = HealthStatisticsReader(
      buckets: { _, start, end in
        asked.withValue { $0.append(DateInterval(start: start, end: end)) }
        return buckets.filter { $0.start >= start && $0.start < end }
      },
      isPairedWithWatch: { true })
    $0.healthBatchUploader = uploads.uploader
    $0.healthBackfillStorage = storage
    $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
    $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
    $0.uuid = .incrementing
    $0.date.now = now
  } operation: {
    HealthBackfill(types: types)
  }
}

/// A day ahead of `now`: sums run that far, for samples logged ahead of time.
private let lookahead = now.addingTimeInterval(86_400)

struct HealthStatisticsTests {
  @Test
  func theBackfillUploadsSumsInChunksWithTheDevice() async throws {
    // Samples from a year ago.
    let firstSample = now.addingTimeInterval(-365 * 86_400 + 600)
    let old = HealthBucket(start: HealthEncoder.bucketStart(of: firstSample), sum: 50)
    let recent = HealthBucket(start: now.addingTimeInterval(-3600), sum: 1234)
    let uploads = Uploads()
    let asked = LockIsolated<[DateInterval]>([])
    let backfill = makeBackfill(
      pages: LockIsolated([page(starts: [firstSample])]), buckets: [old, recent],
      uploads: uploads, asked: asked)

    try await backfill.run()

    // From the earliest sample's bucket to a day ahead, 90 days at a time.
    #expect(asked.value.first?.start == HealthEncoder.bucketStart(of: firstSample))
    #expect(asked.value.last?.end == lookahead)
    #expect(asked.value.allSatisfy { $0.duration <= 90 * 86_400 })
    #expect(asked.value.count == 5)
    // Buckets with data, and zeros only for the last month (and the day ahead).
    let rows = uploads.rows("health_statistic")
    #expect(rows.first?.sum == 50)
    #expect(rows.contains { $0.sum == 1234 && $0.bucketStart == 1_760_482_800_000 })
    // The old bucket, plus every bucket of the last 31 days and the day ahead.
    let expected: Int = 1 + 32 * 48
    #expect(rows.count == expected)
    #expect(rows.allSatisfy { $0.unit == "count" })
    #expect(uploads.ids("health_statistics_device") == ["self"])
    #expect(uploads.rows("health_statistics_device").first?.pairedWithWatch == true)
  }

  @Test
  func recentChangesOverwriteEmptyBucketsWithZeros() async throws {
    let uploads = Uploads()
    let asked = LockIsolated<[DateInterval]>([])
    let backfill = makeBackfill(
      pages: LockIsolated([page(starts: [now.addingTimeInterval(-7200)])]),
      buckets: [HealthBucket(start: now.addingTimeInterval(-7200), sum: 10)], uploads: uploads,
      asked: asked)

    try await backfill.run()

    // Two hours back and a day ahead: one bucket with data, the rest emptied.
    let sums = uploads.rows("health_statistic").compactMap(\.sum)
    #expect(sums.first == 10)
    let expected: Int = 4 + 48
    #expect(sums.count == expected)
    #expect(sums.dropFirst().allSatisfy { $0 == 0 })
  }

  @Test
  func deletionsRecomputeAWeekBeforeTheLastSums() async throws {
    let uploads = Uploads()
    let asked = LockIsolated<[DateInterval]>([])
    let storage = HealthBackfillStorage.inMemory()
    // The app was away for three weeks since the type's sums last went up.
    var state = HealthBackfillState()
    state.anchors[steps.id] = Data("0".utf8)
    state.statisticsUploadedAt[steps.id] = now.addingTimeInterval(-21 * 86_400)
    try storage.saveState(state)
    let backfill = makeBackfill(
      pages: LockIsolated([page(deletions: 1)]), buckets: [], uploads: uploads,
      storage: storage, asked: asked)

    try await backfill.run()

    #expect(asked.value.first?.start == now.addingTimeInterval(-28 * 86_400))
    #expect(try storage.loadState()?.statisticsUploadedAt[steps.id] == now)
  }

  @Test
  func samplesLoggedAheadOfTimeGetTheirSums() async throws {
    let later = now.addingTimeInterval(7200)
    let uploads = Uploads()
    let asked = LockIsolated<[DateInterval]>([])
    let backfill = makeBackfill(
      pages: LockIsolated([page(starts: [later])]),
      buckets: [HealthBucket(start: later, sum: 3)], uploads: uploads, asked: asked)

    try await backfill.run()

    #expect(
      asked.value == [
        DateInterval(
          start: later, end: HealthEncoder.bucketStart(of: later.addingTimeInterval(86_400)))
      ])
    #expect(uploads.rows("health_statistic").first?.sum == 3)
  }

  @Test
  func failedSumsAreKeptWithoutFailingTheSamples() async throws {
    let uploads = Uploads()
    // The first chunk goes up, then uploads fail.
    uploads.failSumsAfter.setValue(1)
    let asked = LockIsolated<[DateInterval]>([])
    let storage = HealthBackfillStorage.inMemory()
    let firstSample = now.addingTimeInterval(-200 * 86_400)
    let backfill = makeBackfill(
      pages: LockIsolated([page(starts: [firstSample])]),
      buckets: [HealthBucket(start: HealthEncoder.bucketStart(of: firstSample), sum: 1)],
      uploads: uploads, storage: storage, asked: asked)

    await withKnownIssue {
      try await backfill.run()
    }
    // The samples are done; the sums resume after the chunk that went up.
    let state = try #require(try storage.loadState())
    #expect(state.finished == [steps.id])
    #expect(
      state.statisticsFrom[steps.id]
        == HealthEncoder.bucketStart(of: firstSample).addingTimeInterval(90 * 86_400))
    var updates = await backfill.progressUpdates().makeAsyncIterator()
    #expect(await updates.next()?.failure == nil)

    uploads.failSumsAfter.setValue(nil)
    try await backfill.run()
    #expect(try storage.loadState()?.statisticsFrom.isEmpty == true)
  }

  @Test
  func theDeviceGoesUpOncePerRun() async throws {
    let energy = HealthBackfillType(id: "HKQuantityTypeIdentifierActiveEnergyBurned")
    let uploads = Uploads()
    let asked = LockIsolated<[DateInterval]>([])
    let backfill = makeBackfill(
      [steps, energy],
      pages: LockIsolated([page(starts: [now]), page(starts: [now])]), buckets: [],
      uploads: uploads, asked: asked)

    try await backfill.run()

    #expect(uploads.ids("health_statistics_device") == ["self"])
  }

  @Test
  func discreteTypesHaveNoSums() async throws {
    let uploads = Uploads()
    let backfill = withDependencies {
      $0.healthReader = HealthReader { _, _, _ in page(starts: [now]) }
      $0.healthBatchUploader = uploads.uploader
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.uuid = .incrementing
      $0.date.now = now
    } operation: {
      HealthBackfill(types: [HealthBackfillType(id: "HKQuantityTypeIdentifierBodyMass")])
    }
    try await backfill.run()
    #expect(uploads.ids("health_statistic").isEmpty)
  }

  @Test
  func stateSavedBeforeStatisticsStillDecodes() throws {
    let saved = #"{"anchors":{},"finished":["x"],"empty":[],"uploadedRecords":3}"#
    let state = try JSONDecoder().decode(HealthBackfillState.self, from: Data(saved.utf8))
    #expect(state.finished == ["x"])
    #expect(state.statisticsFrom.isEmpty)
  }

  @Test
  func bucketsStartOnUTCHalfHours() {
    #expect(
      HealthEncoder.bucketStart(of: Date(timeIntervalSince1970: 1_760_400_000 + 1799))
        == Date(timeIntervalSince1970: 1_760_400_000))
    let mutation = HealthEncoder.statistic(
      type: steps.id,
      bucket: HealthBucket(start: Date(timeIntervalSince1970: 1_760_400_000), sum: 5),
      unit: "count")
    #expect(mutation.id == "HKQuantityTypeIdentifierStepCount@1760400000000")
  }
}
