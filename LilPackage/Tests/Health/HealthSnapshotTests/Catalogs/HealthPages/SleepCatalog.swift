#if os(macOS)
  import Foundation
  import HealthCatalog
  @testable import HealthDatabase
  @testable import HealthPages
  import SQLiteData
  import SwiftUI
  import Testing

  // Sleep (`SleepDetailContent`): half a year of synthetic nights (`sleepCatalogDatabase`), read as
  // the page reads them, at each range, and a made-up night without stages. Highlights (851-3103)
  // are today's whatever the period, so most states leave them out, as without enough data; a few
  // show them on the page, and made-up ones show them alone. Synthetic data only.

  extension MacSnapshotTests {
    @Test(arguments: sleepCatalog.selectedStates)
    func sleep(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let sleepCatalog = StateCatalog(
    "Sleep", width: 760, minHeight: 760,
    states: [
      CatalogState("Night") { detail(.day, .loaded(nights(.day))) },
      // Today and the next night are available (851-2866).
      CatalogState("The night before") {
        detail(.day, offset: -1, .loaded(nights(.day, offset: -1)))
      },
      // ‹ pressed: tonight stays, with a spinner, until the night before loads (851-3084).
      CatalogState("Night, loading the night before") {
        detail(.day, offset: -1, .loaded(nights(.day), isUpdating: true))
      },
      // Up for an hour in the night, with nothing recorded: one night, with a gap.
      CatalogState("Night with a gap") {
        detail(.day, offset: -2, .loaded(nights(.day, offset: -2)))
      },
      // E.g. an iPhone's estimate, without a Watch: asleep and awake only.
      CatalogState("Night without stages") {
        let day = previewCalendar.startOfDay(for: previewNow)
        let segments = [
          SleepSegment(
            stage: .asleep, start: day.addingTimeInterval(-3600),
            end: day.addingTimeInterval(3 * 3600)),
          SleepSegment(
            stage: .awake, start: day.addingTimeInterval(3 * 3600),
            end: day.addingTimeInterval(3.3 * 3600)),
          SleepSegment(
            stage: .asleep, start: day.addingTimeInterval(3.3 * 3600),
            end: day.addingTimeInterval(6.5 * 3600)),
        ]
        detail(
          .day,
          .loaded(
            SleepPeriod(
              range: .day, firstDay: day, lastDay: day,
              nights: [SleepNight(day: day, segments: segments, inBed: 8 * 3600)])))
      },
      // The night the Watch was charging.
      CatalogState("No sleep") { detail(.day, offset: -3, .loaded(nights(.day, offset: -3))) },
      // At clock time, from bedtime to waking: a night that started after midnight, one with a
      // gap, and one missing.
      CatalogState("Week") { detail(.week, .loaded(nights(.week))) },
      CatalogState("Week, loading the week before") {
        detail(.week, offset: -1, .loaded(nights(.week), isUpdating: true))
      },
      CatalogState("Month") { detail(.month, .loaded(nights(.month))) },
      CatalogState("Month, loading the month before") {
        detail(.month, offset: -1, .loaded(nights(.month), isUpdating: true))
      },
      // Before the catalog's nights start.
      CatalogState("Month without sleep") {
        detail(.month, offset: -8, .loaded(nights(.month, offset: -8)))
      },
      // A bar a week, across the start of daylight saving time (March 10), which doesn't move the
      // nights after it.
      CatalogState("6 Months") { detail(.sixMonths, .loaded(nights(.sixMonths))) },
      CatalogState("6 Months, loading the 6 months before") {
        detail(.sixMonths, offset: -1, .loaded(nights(.sixMonths), isUpdating: true))
      },
      CatalogState("Loading") { detail(.day, .loading) },
      CatalogState("Loading a month") { detail(.month, .loading) },
      CatalogState("Failed") { detail(.week, .failed("The database couldn't be read.")) },
      // Below Show All Data and Data Sources, which don't move as they load or come and go. Taller
      // than the page, so its window doesn't grow to fit, to a half point, which moved everything
      // in it by 0.5 pt (`LayoutShiftTests`).
      CatalogState("Night with highlights", minHeight: 1200) {
        detail(.day, .loaded(nights(.day)), highlights: .loaded(highlights))
      },
      CatalogState("Highlights loading") {
        detail(.day, .loaded(nights(.day)), highlights: .loading)
      },
      CatalogState("Highlights failed") {
        detail(
          .day, .loaded(nights(.day)), highlights: .failed("The database couldn't be read."))
      },
      // Bed after midnight, past an hour later than usual.
      CatalogState("Bedtime later than usual", minHeight: 300) {
        highlightsOnly(SleepHighlights(bedtime: bedtime(lastNight: 0.4)))
      },
      // Within 5 minutes of the average.
      CatalogState("Bedtime as usual", minHeight: 300) {
        highlightsOnly(SleepHighlights(bedtime: bedtime(lastNight: -1.05)))
      },
      // 5% or more under last month's average.
      CatalogState("Less sleep this month", minHeight: 250) {
        highlightsOnly(SleepHighlights(months: months(this: 6.9 * 3600, last: 7.65 * 3600)))
      },
      CatalogState("More sleep this month", minHeight: 250) {
        highlightsOnly(SleepHighlights(months: months(this: 8.2 * 3600, last: 7.65 * 3600)))
      },
    ],
    // What's below the content stays put while it loads, and from one range to another but D,
    // which lists the night's stages (851-3084).
    sameLayout: [
      [
        "Loading", "Night", "The night before", "Night, loading the night before",
        "Night with a gap", "Night with highlights", "Highlights loading", "Highlights failed",
      ],
      [
        "Week", "Week, loading the week before", "Month", "Month, loading the month before",
        "Month without sleep", "6 Months", "6 Months, loading the 6 months before",
        "Loading a month", "Failed",
      ],
    ])

  private let sleepType = HealthCatalog.type(id: HealthDatabase.sleepType)!

  private func nights(_ range: SleepRange, offset: Int = 0) -> SleepPeriod {
    try! sleepCatalogDatabase.read { db in
      try SleepRequest(range: range, offset: offset, day: previewNow, calendar: previewCalendar)
        .fetch(db)!
    }
  }

  /// Today's highlights, read as the page reads them.
  private var highlights: SleepHighlights {
    try! sleepCatalogDatabase.read { db in
      try SleepHighlightsRequest(day: previewNow, calendar: previewCalendar).fetch(db)!
    }
  }

  /// Two weeks of made-up bedtimes around 11 PM, a night missing, then last night's at
  /// `lastNight` hours from midnight.
  private func bedtime(lastNight: Double) -> BedtimeConsistency {
    let today = previewCalendar.startOfDay(for: previewNow)
    let day = { previewCalendar.date(byAdding: .day, value: $0, to: today)! }
    let earlier = [-1.2, -0.9, -1.0, -1.3, -0.8, -1.1, -1.0, -1.25, -0.95, nil, -1.05, -1.2, -0.85]
    let nights = earlier.enumerated().compactMap { index, bedtime in
      bedtime.map { BedtimeConsistency.Night(day: day(index - 13), bedtime: $0) }
    }
    return BedtimeConsistency(
      firstDay: day(-13), nights: nights + [.init(day: today, bedtime: lastNight)])
  }

  /// Made-up averages for August so far and July.
  private func months(this: TimeInterval, last: TimeInterval) -> SleepMonthComparison {
    let thisMonth = previewCalendar.dateInterval(of: .month, for: previewNow)!.start
    return SleepMonthComparison(
      thisMonth: thisMonth,
      lastMonth: previewCalendar.date(byAdding: .month, value: -1, to: thisMonth)!,
      thisMonthAverage: this, lastMonthAverage: last)
  }

  /// Without enough data for highlights, unless it's given them.
  @MainActor
  private func detail(
    _ range: SleepRange, offset: Int = 0, _ state: SleepDetailContent.State,
    highlights: SleepHighlightsSection.State = .loaded(SleepHighlights())
  ) -> some View {
    NavigationStack {
      SleepDetailContent(
        type: sleepType, range: .constant(range), offset: .constant(offset), state: state,
        highlights: highlights, now: previewNow)
    }
  }

  /// The highlights' section alone, in a form as the page has it.
  @MainActor
  private func highlightsOnly(_ highlights: SleepHighlights) -> some View {
    Form {
      SleepHighlightsSection(state: .loaded(highlights))
    }
    .formStyle(.grouped)
  }

  /// 200 synthetic nights, a Watch's, ending with `previewNow`'s: in bed from about 10:30 to 11:45
  /// PM for 6.5 to 8 hours, in 90-minute cycles of Core, Deep, Core and REM, sometimes awake a few
  /// minutes between them. The same every run. The week before `previewNow` has what the page has
  /// to handle: a night that starts after midnight (Aug 9), none (Aug 10), and one with an hour
  /// awake and unrecorded, then a nap that isn't part of it (Aug 11).
  let sleepCatalogDatabase: any DatabaseWriter = {
    let calendar = previewCalendar
    let today = calendar.startOfDay(for: previewNow)
    var random = SplitMix64(seed: "sleepCatalogDatabase")
    var samples: [HealthSample] = []
    func record(_ stage: SleepStage, _ start: Date, _ end: Date) {
      samples.append(
        HealthSample(
          id: "sleep-\(samples.count)", type: HealthDatabase.sleepType,
          startDate: start.unixMilliseconds, endDate: end.unixMilliseconds,
          categoryValue: stage.rawValue, sourceName: "Apple Watch",
          sourceBundleID: "com.apple.health.watch"))
    }
    /// Cycles of stages from `start` to `end`, cut off at `end`.
    func stages(from start: Date, to end: Date) {
      var time = start
      while time < end {
        for (stage, minutes) in [
          (SleepStage.core, 20...40.0), (.deep, 15...35), (.core, 10...25), (.rem, 15...30),
        ] {
          let next = min(time.addingTimeInterval(random.next(in: minutes) * 60), end)
          if next > time { record(stage, time, next) }
          time = next
        }
        if time < end, random.next(in: 0...1) < 0.4 {
          let next = min(time.addingTimeInterval(random.next(in: 3...9) * 60), end)
          record(.awake, time, next)
          time = next
        }
      }
    }
    for back in (0..<200).reversed() {
      guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
      // Bedtime and waking by the clock, in hours from the day's start.
      var bedtime = random.next(in: -1.5 ... -0.25)
      let length = random.next(in: 6.5...8)
      switch back {
      case 3: continue
      case 4: bedtime = 0.65
      default: break
      }
      let clock = { (hours: Double) -> Date in
        // The clock's time, not the time elapsed, so nights across DST keep their hours.
        let minutes = Int((hours * 60).rounded())
        let hour = Int((Double(minutes) / 60).rounded(.down))
        let minute = minutes - hour * 60
        let base = calendar.date(byAdding: .day, value: hour < 0 ? -1 : 0, to: day)!
        return calendar.date(
          bySettingHour: (hour + 24) % 24, minute: minute, second: 0, of: base)!
      }
      let start = clock(bedtime)
      let end = clock(bedtime + length)
      if back == 2 {
        let gap = clock(2)
        let resume = clock(2.9)
        stages(from: start, to: gap)
        stages(from: resume, to: end)
        record(.asleep, clock(15), clock(15.6))
      } else {
        stages(from: start, to: end)
      }
      record(.inBed, start.addingTimeInterval(-12 * 60), end.addingTimeInterval(8 * 60))
    }
    do {
      let database = try HealthDatabase.make()
      try database.write { db in try HealthSample.insert { samples }.execute(db) }
      return database
    } catch {
      fatalError("Couldn't make the sleep catalog's database: \(error)")
    }
  }()

#endif
