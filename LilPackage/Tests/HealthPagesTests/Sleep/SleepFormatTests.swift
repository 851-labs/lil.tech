import Foundation
import HealthDatabase
import Testing

@testable import HealthPages

struct SleepFormatTests {
  @Test
  func durationsReadLikeHealth() {
    #expect(SleepFormat.duration(45 * 60) == "45 min")
    #expect(SleepFormat.duration(7 * 3600) == "7 hr")
    #expect(SleepFormat.duration(7 * 3600 + 32 * 60) == "7 hr 32 min")
  }

  @Test
  func rowsFollowWhatTheSourceRecorded() {
    let day = Date(timeIntervalSince1970: 1_760_400_000)
    let staged = SleepNight(
      day: day, segments: [SleepSegment(stage: .deep, start: day, end: day + 60)], inBed: 60)
    #expect(SleepFormat.rows(for: staged) == [.awake, .rem, .core, .deep])
    let estimated = SleepNight(
      day: day, segments: [SleepSegment(stage: .asleep, start: day, end: day + 60)], inBed: 60)
    #expect(SleepFormat.rows(for: estimated) == [.awake, .asleep])
    // A staged night with some unspecified sleep too shows it as its own row.
    let mixed = SleepNight(
      day: day,
      segments: [
        SleepSegment(stage: .deep, start: day, end: day + 60),
        SleepSegment(stage: .asleep, start: day + 60, end: day + 120),
      ], inBed: 120)
    #expect(SleepFormat.rows(for: mixed) == [.awake, .rem, .core, .deep, .asleep])
  }
}
