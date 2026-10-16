import Dependencies
import HealthUpload
import Testing

@testable import HealthPhoneApp

struct HealthBackgroundWorkTests {
  /// Synthetic progress: `withData` finished types of `records` records each, `empty` finished
  /// types without any, out of `total`.
  private func progress(withData: Int, empty: Int, records: Int, total: Int)
    -> HealthBackfill.Progress
  {
    var types: [String: HealthBackfill.TypeProgress] = [:]
    for index in 0..<withData {
      types["data-\(index)"] = .init(isDone: true, uploadedRecords: records)
    }
    for index in 0..<empty { types["empty-\(index)"] = .init(isDone: true, uploadedRecords: 0) }
    for index in (withData + empty)..<total {
      types["left-\(index)"] = .init(isDone: false, uploadedRecords: 0)
    }
    return HealthBackfill.Progress(
      finishedTypes: withData + empty, totalTypes: total, uploadedRecords: withData * records,
      isRunning: true, types: types)
  }

  @Test
  func anUploadReportsRecordsAgainstAnEstimatedTotal() {
    // Each type left counts as much as an average finished one with data; empty ones don't.
    let upload = HealthBackgroundWork.UploadProgress(
      progress(withData: 5, empty: 5, records: 10_000, total: 40))
    #expect(upload.completed == 50_000)
    #expect(upload.total == 50_000 + 30 * 10_000)
    #expect(upload.subtitle == "10 of 40 types · 50,000 records")
  }

  @Test
  func countedRecordsMakeTheTotalExact() {
    var counted = progress(withData: 5, empty: 5, records: 10_000, total: 40)
    counted.totalRecords = 1_234_567
    let upload = HealthBackgroundWork.UploadProgress(counted)
    #expect(upload.completed == 50_000)
    #expect(upload.total == 1_234_567)
    #expect(upload.subtitle == "50,000 of 1,234,567 records")
  }

  @Test
  func theEstimateNeverReachesTheEndEarly() {
    // Empty types done first don't make the end look near.
    let emptyFirst = HealthBackgroundWork.UploadProgress(
      progress(withData: 0, empty: 35, records: 0, total: 40))
    #expect(emptyFirst.completed < emptyFirst.total)
    let almost = HealthBackgroundWork.UploadProgress(
      progress(withData: 39, empty: 0, records: 100, total: 40))
    #expect(almost.completed < almost.total)
    // Done: complete.
    let done = HealthBackgroundWork.UploadProgress(
      progress(withData: 40, empty: 0, records: 100, total: 40))
    #expect(done.completed == done.total)
  }

  @Test
  func aContinuedUploadPausesWhileThePhoneIsLocked() async {
    let outcomes = LockIsolated<[HealthBackgroundWork.RunOutcome]>([.locked, .locked, .finished])
    let events = LockIsolated<[String]>([])
    let finished = await HealthBackgroundWork.runUntilDone(
      run: {
        events.withValue { $0.append("run") }
        return outcomes.withValue { $0.removeFirst() }
      },
      unlocked: { events.withValue { $0.append("unlocked") } },
      paused: { paused in events.withValue { $0.append(paused ? "paused" : "resumed") } })
    #expect(finished)
    #expect(
      events.value == [
        "run", "paused", "unlocked", "resumed", "run", "paused", "unlocked", "resumed", "run",
      ])
  }

  @Test
  func aContinuedUploadStopsOnAnyOtherFailure() async {
    let runs = LockIsolated(0)
    let finished = await HealthBackgroundWork.runUntilDone(
      run: {
        runs.withValue { $0 += 1 }
        return .stopped
      },
      unlocked: { Issue.record("Waited for an unlock") },
      paused: { _ in Issue.record("Paused") })
    #expect(!finished)
    #expect(runs.value == 1)
  }

  // A hang would block the pre-commit hook: fail instead.
  @Test(.timeLimit(.minutes(1)))
  func anExpiredContinuedUploadStopsWaitingForAnUnlock() async {
    let runs = LockIsolated(0)
    let task = Task {
      await HealthBackgroundWork.runUntilDone(
        run: {
          runs.withValue { $0 += 1 }
          return .locked
        },
        // Locked until the task is cancelled.
        unlocked: { try? await Task.sleep(for: .seconds(60)) },
        paused: { _ in })
    }
    while runs.value == 0 { await Task.yield() }
    task.cancel()
    #expect(await task.value == false)
    #expect(runs.value == 1)
  }
}
