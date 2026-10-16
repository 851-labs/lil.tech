import HealthUpload
import Testing

@testable import HealthPhoneApp

struct HealthBackgroundWorkTests {
  private func progress(finished: Int, total: Int, records: Int) -> HealthBackfill.Progress {
    HealthBackfill.Progress(
      finishedTypes: finished, totalTypes: total, uploadedRecords: records, isRunning: true)
  }

  @Test
  func anUploadReportsRecordsAgainstAnEstimatedTotal() {
    // A quarter of the types done with 50,000 records: about 200,000 in all.
    let upload = HealthBackgroundWork.UploadProgress(
      progress(finished: 10, total: 40, records: 50_000))
    #expect(upload.completed == 50_000)
    #expect(upload.total == 200_000)
    #expect(upload.subtitle == "10 of 40 types · 50,000 records")
  }

  @Test
  func theEstimateNeverReachesTheEndEarly() {
    // Before the first type is done, it counts as one.
    let starting = HealthBackgroundWork.UploadProgress(
      progress(finished: 0, total: 40, records: 2_000))
    #expect(starting.total == 80_000)
    // Nothing uploaded yet: still short of done.
    let empty = HealthBackgroundWork.UploadProgress(progress(finished: 0, total: 40, records: 0))
    #expect(empty.completed < empty.total)
    // All but the last type: still short of done.
    let almost = HealthBackgroundWork.UploadProgress(
      progress(finished: 39, total: 40, records: 100))
    #expect(almost.completed < almost.total)
    // Done: complete.
    let done = HealthBackgroundWork.UploadProgress(progress(finished: 40, total: 40, records: 100))
    #expect(done.completed == done.total)
  }
}
