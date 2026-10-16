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

  /// Runs `runUntilDone` with these outcomes in turn, recording what it did.
  private func run(
    _ outcomes: [HealthBackgroundWork.RunOutcome]
  ) async -> (finished: Bool, events: [String]) {
    let outcomes = LockIsolated(outcomes)
    let events = LockIsolated<[String]>([])
    let finished = await HealthBackgroundWork.runUntilDone(
      run: {
        events.withValue { $0.append("run") }
        return outcomes.withValue { $0.isEmpty ? .stopped : $0.removeFirst() }
      },
      unlocked: { events.withValue { $0.append("unlocked") } },
      online: { events.withValue { $0.append("online") } },
      wait: { delay in events.withValue { $0.append("wait \(delay.components.seconds)") } },
      notice: { notice in
        events.withValue { $0.append(notice.map { "notice \($0)" } ?? "cleared") }
      })
    return (finished, events.value)
  }

  @Test
  func aContinuedUploadPausesWhileThePhoneIsLocked() async {
    let (finished, events) = await run([.locked, .finished])
    #expect(finished)
    #expect(events == ["run", "notice locked", "unlocked", "cleared", "run"])
  }

  @Test
  func aContinuedUploadPausesWhileOffline() async {
    // Offline doesn't use up the retries.
    let (finished, events) = await run([.offline, .offline, .finished])
    #expect(finished)
    #expect(
      events == [
        "run", "notice offline", "online", "cleared", "run", "notice offline", "online", "cleared",
        "run",
      ])
  }

  @Test
  func aRunWithAFailedTypeIsTriedAgainAfterAWhile() async {
    let (finished, events) = await run([.failed("503", madeProgress: false), .finished])
    // One failed type doesn't end the upload.
    #expect(finished)
    #expect(events == ["run", "notice retrying(\"503\")", "wait 15", "cleared", "run"])
  }

  @Test
  func aTypeThatKeepsFailingEndsTheUploadAfterTheRetries() async {
    let failures = Array(
      repeating: HealthBackgroundWork.RunOutcome.failed("Steps", madeProgress: false),
      count: HealthBackgroundWork.retryDelays.count + 1)
    let (finished, events) = await run(failures)
    #expect(!finished)
    #expect(events.filter { $0 == "run" }.count == HealthBackgroundWork.retryDelays.count + 1)
    #expect(
      events.filter { $0.hasPrefix("wait") } == ["wait 15", "wait 30", "wait 60", "wait 120"])
    // Says why at the end.
    #expect(events.last == "notice failed(\"Steps\")")
  }

  @Test
  func aRunThatUploadedSomethingStartsTheRetriesOver() async {
    let (finished, events) = await run([
      .failed("503", madeProgress: false), .failed("503", madeProgress: false),
      .failed("503", madeProgress: true), .finished,
    ])
    #expect(finished)
    #expect(events.filter { $0.hasPrefix("wait") } == ["wait 15", "wait 30", "wait 15"])
  }

  @Test
  func aContinuedUploadStopsWhenItCantGoOn() async {
    let (finished, events) = await run([.stopped])
    #expect(!finished)
    #expect(events == ["run"])
  }

  @Test
  func reasonsAreReadable() {
    struct Plain: Error {}
    #expect(
      HealthBackgroundWork.reason(HealthBatchUploader.StorageFull())
        == "Your lil account's storage is full")
    #expect(HealthBackgroundWork.reason(Plain()) == "Some Health data couldn't be uploaded.")
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
        online: {},
        wait: { _ in },
        notice: { _ in })
    }
    while runs.value == 0 { await Task.yield() }
    task.cancel()
    #expect(await task.value == false)
    #expect(runs.value == 1)
  }
}
