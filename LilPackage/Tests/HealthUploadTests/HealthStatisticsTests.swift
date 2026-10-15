import Dependencies
import Foundation
import GzipFiles
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
  let failing = LockIsolated(false)

  struct Offline: Error {}

  var uploader: HealthBatchUploader {
    HealthBatchUploader { [self] _, file in
      if failing.value { throw Offline() }
      let text = String(decoding: try Gzip.decompress(file), as: UTF8.self)
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
  pages: LockIsolated<[HealthPage]>, buckets: [HealthBucket], uploads: Uploads,
  storage: HealthBackfillStorage = .inMemory(), asked: LockIsolated<[DateInterval]>
) -> HealthBackfill {
  withDependencies {
    $0.healthReader = HealthReader { _, _, _ in
      pages.withValue {
        $0.isEmpty
          ? HealthPage(mutations: [], anchor: Data("1".utf8), hasMore: false) : $0.removeFirst()
      }
    }
    $0.healthStatisticsReader = HealthStatisticsReader(
      buckets: { type, start, end in
        #expect(type == steps.id)
        asked.withValue { $0.append(DateInterval(start: start, end: end)) }
        return buckets
      },
      isPairedWithWatch: { true })
    $0.healthBatchUploader = uploads.uploader
    $0.healthBackfillStorage = storage
    $0.uuid = .incrementing
    $0.date.now = now
  } operation: {
    HealthBackfill(types: [steps])
  }
}

struct HealthStatisticsTests {
  @Test
  func theBackfillUploadsSumsWithTheDevice() async throws {
    // Samples from a year ago: only buckets with data go up.
    let firstSample = now.addingTimeInterval(-365 * 86_400 + 600)
    let bucket = HealthBucket(start: now.addingTimeInterval(-3600), sum: 1234)
    let uploads = Uploads()
    let asked = LockIsolated<[DateInterval]>([])
    let backfill = makeBackfill(
      pages: LockIsolated([page(starts: [firstSample])]), buckets: [bucket], uploads: uploads,
      asked: asked)

    try await backfill.run()

    // From the bucket the earliest sample is in, to now.
    #expect(
      asked.value == [DateInterval(start: HealthEncoder.bucketStart(of: firstSample), end: now)])
    #expect(uploads.ids("health_statistic") == ["HKQuantityTypeIdentifierStepCount@1760482800000"])
    let row = try #require(uploads.rows("health_statistic").first)
    #expect(row.sum == 1234)
    #expect(row.unit == "count")
    #expect(row.bucketStart == 1_760_482_800_000)
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

    // The four buckets of the last two hours: one with data, three emptied.
    let sums = uploads.rows("health_statistic").compactMap(\.sum)
    #expect(sums == [10, 0, 0, 0])
  }

  @Test
  func deletionsRecomputeTheLastWeek() async throws {
    let uploads = Uploads()
    let asked = LockIsolated<[DateInterval]>([])
    let backfill = makeBackfill(
      pages: LockIsolated([page(deletions: 1)]), buckets: [], uploads: uploads, asked: asked)

    try await backfill.run()

    #expect(asked.value.first?.start == now.addingTimeInterval(-7 * 86_400))
    #expect(uploads.ids("health_statistic").count == 7 * 48)
  }

  @Test
  func failedSumsAreTriedAgain() async throws {
    let uploads = Uploads()
    uploads.failing.setValue(true)
    let asked = LockIsolated<[DateInterval]>([])
    let storage = HealthBackfillStorage.inMemory()
    let backfill = makeBackfill(
      pages: LockIsolated([page(starts: [now.addingTimeInterval(-600)])]), buckets: [],
      uploads: uploads, storage: storage, asked: asked)

    await #expect(throws: Uploads.Offline.self) { try await backfill.run() }
    #expect(try storage.loadState()?.statisticsFrom[steps.id] != nil)

    uploads.failing.setValue(false)
    try await backfill.run()
    #expect(try storage.loadState()?.statisticsFrom.isEmpty == true)
    #expect(!uploads.ids("health_statistic").isEmpty)
  }

  @Test
  func discreteTypesHaveNoSums() async throws {
    let uploads = Uploads()
    let backfill = withDependencies {
      $0.healthReader = HealthReader { _, _, _ in page(starts: [now]) }
      $0.healthBatchUploader = uploads.uploader
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
