public import Foundation

// Windows as stretches of time (docs/decisions/cards.md, Event windows and Times of day). A
// reading is in a window when its start is in one of its stretches, half-open. Times of day make
// theirs from the clock; sleep windows from nights (`CardNights`), and workout windows from
// workouts (851-3196). Every kind keeps readings with `CardWindows.readings(_:in:)`.

/// A workout, as every engine reads it.
public struct CardWorkout: Hashable, Sendable {
  /// Unix milliseconds.
  public var start: Int
  public var end: Int
  /// `HKWorkoutActivityType`'s raw value, the workout's overall activity.
  public var activityType: Int

  public init(start: Int, end: Int, activityType: Int) {
    self.start = start
    self.end = end
    self.activityType = activityType
  }
}

/// What a run with sleep or workout windows fetches before their readings
/// (`CardRun.windowFetches`): nights and workouts, whose stretches say which readings to fetch.
public enum CardWindowFetch: Hashable, Sendable {
  /// Sleep analysis records (`CardSleepRecord`) that end after the range starts and start before
  /// it ends (Unix milliseconds), by start: what `CardNights.nights` groups. Every value and
  /// source, In Bed included.
  case sleep(Range<Int>)
  /// Workouts (`CardWorkout`) of every activity that end after the range starts and start before
  /// it ends (Unix milliseconds).
  case workouts(Range<Int>)
}

/// What was fetched for a `CardWindowFetch`.
public enum CardWindowFetchResult: Hashable, Sendable {
  case sleep([CardSleepRecord])
  case workouts([CardWorkout])
}

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

extension CardWindows {
  /// A sleep window's stretches over `nights` (by day), in order and apart, each with the night it
  /// belongs to. Only nights' sleep: a day's (`CardNight.nightBedtime(calendar:)`) has none.
  /// - `asleep`: each night's stretches asleep.
  /// - `beforeSleep`: `[F − minutes, F)`.
  /// - `afterWaking`: `[W, W + minutes)`.
  ///
  /// Where two nights' stretches overlap, the later night's keeps the overlap, so a reading in
  /// both counts for the later night, and the earlier's stretch ends (or pauses) where the later's
  /// starts.
  static func sleepStretches(
    _ window: CardSpec.Window, nights: [CardNight], calendar: Calendar
  ) -> (stretches: [CardStretch], nights: [Date]) {
    var owned: [(stretch: CardStretch, night: Int)] = []
    for (index, night) in nights.enumerated() where night.nightBedtime(calendar: calendar) != nil {
      switch window {
      case .asleep:
        owned += night.asleepStretches.map { ($0, index) }
      case .beforeSleep(let minutes):
        if let start = night.fallingAsleep {
          owned.append((CardStretch(start: start - minutes * 60_000, end: start), index))
        }
      case .afterWaking(let minutes):
        if let end = night.waking {
          owned.append((CardStretch(start: end, end: end + minutes * 60_000), index))
        }
      case .workout, .timeOfDay:
        break
      }
    }
    let resolved = latestOwnerWins(owned)
    return (resolved.map(\.stretch), resolved.map { nights[$0.night].day })
  }

  /// Stretches made apart, by start: where several overlap, the one with the greatest owner keeps
  /// the overlap. One owner's stretches are apart already.
  static func latestOwnerWins(
    _ stretches: [(stretch: CardStretch, night: Int)]
  ) -> [(stretch: CardStretch, night: Int)] {
    // Nothing overlaps, as almost always: sorted, they're the answer.
    let sorted = stretches.filter { $0.stretch.start < $0.stretch.end }
      .sorted { ($0.stretch.start, $0.night) < ($1.stretch.start, $1.night) }
    guard zip(sorted, sorted.dropFirst()).contains(where: { $0.stretch.end > $1.stretch.start })
    else { return sorted }
    // A sweep over every start and end: between two of them, the greatest owner among the
    // stretches open there keeps the time.
    var events: [(time: Int, opens: Bool, night: Int)] = []
    for (stretch, night) in sorted {
      events.append((stretch.start, true, night))
      events.append((stretch.end, false, night))
    }
    events.sort { $0.time < $1.time }
    var open: [Int: Int] = [:]
    var resolved: [(stretch: CardStretch, night: Int)] = []
    var index = 0
    var previous: Int?
    while index < events.count {
      let time = events[index].time
      if let previous, let owner = open.keys.max(), previous < time {
        if let last = resolved.last, last.night == owner, last.stretch.end == previous {
          resolved[resolved.count - 1].stretch.end = time
        } else {
          resolved.append((CardStretch(start: previous, end: time), owner))
        }
      }
      while index < events.count, events[index].time == time {
        let event = events[index]
        open[event.night, default: 0] += event.opens ? 1 : -1
        if open[event.night] == 0 { open[event.night] = nil }
        index += 1
      }
      previous = time
    }
    return resolved
  }

  /// A workout window's stretches: each matching workout's `[start, end)` (of `activities`, or
  /// every one), merged where they overlap or touch, and clipped to `span`.
  static func workoutStretches(
    activities: [Int]?, workouts: [CardWorkout], in span: Range<Int>
  ) -> [CardStretch] {
    let matching = workouts.filter { workout in
      activities.map { $0.contains(workout.activityType) } ?? true
    }
    var stretches: [CardStretch] = []
    for workout in matching.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
      let start = max(workout.start, span.lowerBound)
      let end = min(workout.end, span.upperBound)
      guard start < end else { continue }
      if let last = stretches.last, start <= last.end {
        stretches[stretches.count - 1].end = max(last.end, end)
      } else {
        stretches.append(CardStretch(start: start, end: end))
      }
    }
    return stretches
  }
}
