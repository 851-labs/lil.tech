import Foundation
import HealthDatabase
import Testing

@testable import HealthPages

struct SampleFormatTests {
  @Test
  func metadataKeysReadAsWords() {
    #expect(SampleFormat.key("HKMetadataKeyHeartRateMotionContext") == "Heart Rate Motion Context")
    // Another app's key stays as it is.
    #expect(SampleFormat.key("com.example.reading") == "com.example.reading")
  }

  @Test
  func aMomentShowsItsTimeAndASpanBothEnds() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let start = 1_760_400_000_000
    let moment = HealthSample(
      id: "a", type: "x", startDate: start, endDate: start + 30_000, sourceName: "Test",
      sourceBundleID: "com.example")
    var span = moment
    span.endDate = start + 20 * 60_000
    let time = Date.FormatStyle(calendar: utc, timeZone: utc.timeZone).hour().minute()
    #expect(
      SampleFormat.time(moment, calendar: utc) == Date(unixMilliseconds: start).formatted(time))
    #expect(SampleFormat.time(span, calendar: utc) != SampleFormat.time(moment, calendar: utc))
  }
}
