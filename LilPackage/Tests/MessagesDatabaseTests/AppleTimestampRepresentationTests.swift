import Foundation
import MessagesDatabase
import Testing

struct AppleTimestampRepresentationTests {
  @Test
  func decodesNanoseconds() {
    let timestamp = Date.AppleTimestampRepresentation(rawValue: 781_000_000_123_000_000)
    #expect(abs(timestamp.queryOutput.timeIntervalSinceReferenceDate - 781_000_000.123) < 0.000_001)
  }

  @Test
  func decodesSeconds() {
    let timestamp = Date.AppleTimestampRepresentation(rawValue: 781_000_000)
    #expect(timestamp.queryOutput.timeIntervalSinceReferenceDate == 781_000_000)
  }

  @Test
  func decodesReferenceDate() {
    let timestamp = Date.AppleTimestampRepresentation(rawValue: 0)
    #expect(timestamp.queryOutput == Date(timeIntervalSinceReferenceDate: 0))
  }

  @Test
  func encodesNanoseconds() {
    let timestamp = Date.AppleTimestampRepresentation(
      queryOutput: Date(timeIntervalSinceReferenceDate: 781_000_000.5)
    )
    #expect(timestamp.rawValue == 781_000_000_500_000_000)
  }

  @Test
  func roundTripsWithinAMicrosecond() {
    let rawValue: Int64 = 781_234_567_890_000_000
    let timestamp = Date.AppleTimestampRepresentation(rawValue: rawValue)
    let roundTripped = Date.AppleTimestampRepresentation(queryOutput: timestamp.queryOutput)
    #expect(abs(roundTripped.rawValue - rawValue) < 1_000)
  }
}
