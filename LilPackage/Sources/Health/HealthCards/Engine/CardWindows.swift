public import Foundation

// Windows as stretches of time (docs/decisions/cards.md, Event windows and Times of day). A
// reading is in a window when its start is in one of its stretches, half-open. Times of day are
// here; sleep and workout windows (851-3196) make their stretches from nights and workouts, and
// keep readings with `CardWindows.readings(_:in:)` the same way.

extension CardTimeOfDay {
  /// The window's stretches that overlap `span` (Unix milliseconds), in order, clipped to it:
  /// each local day's `[from, to)` on its clock, or `[from, to + 1 day)` crossing midnight.
  ///
  /// Placed with the time zone's offsets rather than per reading: between two of its transitions
  /// the clock is the moment plus a fixed offset, so each stretch is exact there, and a day of a
  /// daylight saving change gets the clock's hours, as the rule (`contains(secondsSinceMidnight:)`)
  /// has them: a skipped hour holds nothing, and a repeated hour counts both times.
  public func stretches(in span: Range<Int>, timeZone: TimeZone) -> [CardStretch] {
    let day = 86_400_000
    let from = self.from.secondsSinceMidnight * 1000
    let to = self.to.secondsSinceMidnight * 1000
    var stretches: [CardStretch] = []
    func append(_ stretch: CardStretch) {
      guard stretch.start < stretch.end else { return }
      if let last = stretches.last, last.end >= stretch.start {
        stretches[stretches.count - 1].end = max(last.end, stretch.end)
      } else {
        stretches.append(stretch)
      }
    }
    var segmentStart = span.lowerBound
    while segmentStart < span.upperBound {
      let date = Date(unixMilliseconds: segmentStart)
      let offset = timeZone.secondsFromGMT(for: date) * 1000
      let transition = timeZone.nextDaylightSavingTimeTransition(after: date)?.unixMilliseconds
      let segmentEnd = min(transition.map { max($0, segmentStart + 1) } ?? .max, span.upperBound)
      // The segment on the local clock, and each local day that can reach it.
      let (localStart, localEnd) = (segmentStart + offset, segmentEnd + offset)
      var dayStart = Self.floor(localStart, day) - day
      while dayStart < localEnd {
        let start = dayStart + from
        let end = from < to ? dayStart + to : dayStart + day + to
        append(
          CardStretch(
            start: max(start, localStart) - offset, end: min(end, localEnd) - offset))
        dayStart += day
      }
      segmentStart = segmentEnd
    }
    return stretches
  }

  private static func floor(_ value: Int, _ divisor: Int) -> Int {
    let quotient = value / divisor
    return value % divisor < 0 ? (quotient - 1) * divisor : quotient * divisor
  }
}

public enum CardWindows {
  /// The readings (oldest first) whose start is in one of `stretches` (in order, apart), with the
  /// index of the stretch each is in.
  public static func readings(
    _ readings: [CardReading], in stretches: [CardStretch]
  ) -> (readings: [CardReading], stretchIndices: [Int]) {
    var kept: [CardReading] = []
    var indices: [Int] = []
    var stretch = 0
    for reading in readings {
      while stretch < stretches.count, stretches[stretch].end <= reading.start { stretch += 1 }
      guard stretch < stretches.count else { break }
      if stretches[stretch].start <= reading.start {
        kept.append(reading)
        indices.append(stretch)
      }
    }
    return (kept, indices)
  }
}
