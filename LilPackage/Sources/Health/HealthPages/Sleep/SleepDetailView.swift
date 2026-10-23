import Charts
import Dependencies
public import HealthCatalog
import HealthDatabase
import HealthUI
import LilUI
import SQLiteData
public import SwiftUI

/// Sleep, as in Health: a night's stages (D), the nights of a week or a month at the clock times
/// they ran (W, M), or a bar a week (6M), with time in bed and asleep, the range and earlier
/// periods in the toolbar, then highlights about the last nights (851-3103). Follows the local
/// database as sync changes it.
public struct SleepDetailView: View {
  let type: HealthDataType
  @State private var range = SleepRange.day
  @State private var offset = 0
  /// Today, moved on at midnight, so the nights shown follow. From the `date` dependency, so
  /// snapshot catalogs fix it (`previewNow`).
  @State private var today: Date
  /// The last nights loaded, for the period they're for. While another period loads, the page
  /// keeps showing them (851-3084).
  @Fetch private var period: SleepPeriod? = nil
  /// Highlights about today's night and the ones before it, whichever period is shown.
  @Fetch private var highlights: SleepHighlights? = nil
  @Dependency(\.date) private var date
  @Dependency(\.calendar) private var calendar

  public init(type: HealthDataType) {
    self.type = type
    @Dependency(\.date.now) var now
    _today = State(initialValue: now)
  }

  public var body: some View {
    SleepDetailContent(
      type: type, range: $range, offset: $offset, state: state, highlights: highlightsState,
      now: today
    )
    // Today's start in the page's calendar, so a new local day is a new load (an ISO date is
    // UTC's, which stayed the same at local midnight west of it).
    .task(id: [
      range.rawValue, String(offset), "\(calendar.startOfDay(for: today).timeIntervalSince1970)",
    ]) {
      _ = try? await $period.load(
        SleepRequest(range: range, offset: offset, day: today, calendar: calendar),
        scheduler: MainQueueScheduler())
    }
    // Highlights are today's, so only a new day loads them again.
    .task(id: calendar.startOfDay(for: today)) {
      _ = try? await $highlights.load(
        SleepHighlightsRequest(day: today, calendar: calendar), scheduler: MainQueueScheduler())
    }
    .onReceive(calendarDayChanges()) {
      today = date.now
    }
  }

  /// The nights loaded last, updating while they're another period's or a load is running.
  private var state: SleepDetailContent.State {
    if let error = $period.loadError { return .failed(error.localizedDescription) }
    guard let period else { return .loading }
    let requested = range.lastDay(offset: offset, now: today, calendar: calendar)
    return .loaded(
      period, isUpdating: $period.isLoading || period.range != range || period.lastDay != requested
    )
  }

  /// The highlights loaded last. A new day's replace them once they've loaded.
  private var highlightsState: SleepHighlightsSection.State {
    if let error = $highlights.loadError { return .failed(error.localizedDescription) }
    return highlights.map { .loaded($0) } ?? .loading
  }
}

/// Health's ranges for Sleep (851-3098), each ending with today's night: D one night, W seven, M
/// the nights since the same day last month, 6M 26 weeks, ending with this one.
enum SleepRange: String, CaseIterable, Hashable, Sendable, PeriodRange {
  case day = "D"
  case week = "W"
  case month = "M"
  case sixMonths = "6M"

  /// D is a night, which runs over two days.
  var periodName: String {
    switch self {
    case .day: "Night"
    case .week: "Week"
    case .month: "Month"
    case .sixMonths: "6 Months"
    }
  }

  /// The last night shown, `offset` periods back from today's.
  func lastDay(offset: Int, now: Date, calendar: Calendar) -> Date {
    let today = calendar.startOfDay(for: now)
    let day: Date? =
      switch self {
      case .day: calendar.date(byAdding: .day, value: offset, to: today)
      case .week: calendar.date(byAdding: .day, value: offset * 7, to: today)
      case .month: calendar.date(byAdding: .month, value: offset, to: today)
      case .sixMonths:
        // The last day of this week, whose bar is the last, though its nights are still to come.
        calendar.dateInterval(of: .weekOfYear, for: today)
          .flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) }
          .flatMap { calendar.date(byAdding: .weekOfYear, value: offset * 26, to: $0) }
      }
    return day.map(calendar.startOfDay) ?? today
  }

  /// The first night shown. A month starts the day after the month before ends, so months
  /// follow each other without a night shown twice, however long they are.
  func firstDay(offset: Int, now: Date, calendar: Calendar) -> Date {
    let last = lastDay(offset: offset, now: now, calendar: calendar)
    let day: Date? =
      switch self {
      case .day: last
      case .week: calendar.date(byAdding: .day, value: -6, to: last)
      case .month:
        calendar.date(
          byAdding: .day, value: 1, to: lastDay(offset: offset - 1, now: now, calendar: calendar))
      case .sixMonths: calendar.date(byAdding: .day, value: 1 - 26 * 7, to: last)
      }
    return day.map(calendar.startOfDay) ?? last
  }
}

/// A period's nights: the range, its first and last nights, and the nights with sleep in it.
struct SleepPeriod: Equatable, Sendable {
  let range: SleepRange
  /// The start of the first night's day.
  let firstDay: Date
  /// The start of the last night's day.
  let lastDay: Date
  let nights: [SleepNight]
  /// 6M's bars, averaged as it loads rather than each time the chart draws.
  var weeks: [SleepWeek] = []
  /// Whether any sleep was ever recorded: a period without nights then shows its chart empty,
  /// and an account without any says so (851-3102).
  var hasSleep = true
}

struct SleepRequest: FetchKeyRequest {
  let range: SleepRange
  let offset: Int
  /// The day it's for, so a new day is a new request.
  let day: Date
  let calendar: Calendar

  init(range: SleepRange, offset: Int, day: Date, calendar: Calendar = .current) {
    self.range = range
    self.offset = offset
    self.day = calendar.startOfDay(for: day)
    self.calendar = calendar
  }

  func fetch(_ db: Database) throws -> SleepPeriod? {
    let firstDay = range.firstDay(offset: offset, now: day, calendar: calendar)
    let lastDay = range.lastDay(offset: offset, now: day, calendar: calendar)
    let count = (calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) + 1
    let nights = try HealthDatabase.sleepNights(
      endingOn: lastDay, count: count, calendar: calendar, db)
    return SleepPeriod(
      range: range, firstDay: firstDay, lastDay: lastDay, nights: nights,
      weeks: range == .sixMonths ? SleepWeek.weeks(nights, calendar: calendar) : [],
      hasSleep: try !nights.isEmpty || HealthDatabase.hasSleep(db))
  }
}

/// What the sleep detail shows, however it got it.
struct SleepDetailContent: View {
  enum State {
    /// Nothing to show yet: placeholders take the loaded page's space (851-3084).
    case loading
    /// A period's nights. Updating while another period, or the same one again, loads: they stay
    /// on screen, with a spinner, rather than the page blanking and shifting.
    case loaded(SleepPeriod, isUpdating: Bool = false)
    case failed(String)

    var isLoading: Bool {
      if case .loading = self { true } else { false }
    }
  }

  let type: HealthDataType
  /// The period chosen in the toolbar, which can be ahead of the one shown (`range`, `days`).
  @Binding private var selectedRange: SleepRange
  @Binding private var selectedOffset: Int
  let state: State
  /// Highlights about the last nights, the page's last section (851-3103).
  let highlights: SleepHighlightsSection.State
  /// Whether the highlights' load has run long enough to show it (851-3086).
  @SwiftUI.State private var highlightsProgress: DelayedProgress
  /// Today, as the page loads it, for the nights shown.
  let now: Date
  /// From dependencies, so snapshot catalogs fix it (`previewCalendar`).
  @Dependency(\.calendar) private var calendar

  init(
    type: HealthDataType, range: Binding<SleepRange>, offset: Binding<Int>, state: State,
    highlights: SleepHighlightsSection.State, now: Date
  ) {
    self.type = type
    _selectedRange = range
    _selectedOffset = offset
    self.state = state
    self.highlights = highlights
    // As they are, so a first render doesn't animate it away.
    _highlightsProgress = SwiftUI.State(
      initialValue: DelayedProgress(isLoading: highlights.isLoading))
    self.now = now
  }

  var body: some View {
    // A grouped form on its own background, as Metric Detail is (851-2989, 851-3000): the summary
    // and the chart, the night's stages, the pages it opens, then the highlights. They go last,
    // after Show All Data as in Health, since what they show is only known once they've loaded:
    // nothing is below them to move when they arrive, or come and go (851-3103).
    Form {
      Section {
        VStack(alignment: .leading, spacing: 12) {
          header
          chartArea
            .delayedProgress(isLoading: state.isLoading)
            .frame(height: 240)
        }
        .padding(.vertical, 6)
      }
      // A night's stages. Placeholders while it loads, so the rows below don't move when it
      // arrives (851-3084).
      if range == .day {
        if let night = nights.last {
          stages(night)
        } else if case .loading = state {
          stagesPlaceholder
        }
      }
      Section {
        NavigationLink("Show All Data") {
          AllDataView(type: type)
        }
        .layoutAnchor("Show All Data")
        NavigationLink("Data Sources") {
          DataSourcesView(type: type)
        }
        .layoutAnchor("Data Sources")
      }
      SleepHighlightsSection(state: highlights, showsProgress: highlightsProgress.isVisible)
    }
    .formStyle(.grouped)
    .onChange(of: highlights.isLoading, initial: true) {
      highlightsProgress.update(isLoading: highlights.isLoading)
    }
    .navigationTitle(type.name)
    // The range and ‹ Today › in the toolbar, as on other metrics (851-2866).
    .periodControls(PagePeriod(range: $selectedRange, offset: $selectedOffset))
  }

  // MARK: Period shown

  /// The period whose nights are shown: the loaded one, which stays while another loads, or the
  /// one chosen before any has loaded. Everything drawn uses it, never the selection.
  private var range: SleepRange {
    if case .loaded(let period, _) = state { period.range } else { selectedRange }
  }

  /// The first and last nights shown.
  private var days: (first: Date, last: Date) {
    if case .loaded(let period, _) = state { return (period.firstDay, period.lastDay) }
    return (
      selectedRange.firstDay(offset: selectedOffset, now: now, calendar: calendar),
      selectedRange.lastDay(offset: selectedOffset, now: now, calendar: calendar)
    )
  }

  private var nights: [SleepNight] {
    if case .loaded(let period, _) = state { period.nights } else { [] }
  }

  private var isLoaded: Bool {
    if case .loaded = state { true } else { false }
  }

  private var isUpdating: Bool {
    if case .loaded(_, let isUpdating) = state { isUpdating } else { false }
  }

  // MARK: Header

  /// Time in bed and time asleep side by side, as in Health, averages over the nights with sleep
  /// for W, M and 6M, then the dates. The same lines whatever the state, so loading never changes
  /// its height (851-3084).
  private var header: some View {
    let nights = nights
    let count = Double(max(nights.count, 1))
    let average = range == .day ? "" : "AVG. "
    return VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .top, spacing: 16) {
        headerValue(average + "TIME IN BED", nights.reduce(0) { $0 + $1.inBed } / count)
        headerValue(average + "TIME ASLEEP", nights.reduce(0) { $0 + $1.asleep } / count)
      }
      Text(span)
        .foregroundStyle(.secondary)
    }
    // While another period loads, over the one shown.
    .updatingIndicator(isUpdating)
  }

  /// One of the header's columns: its label, and the time, "–" while loading or "No Data".
  private func headerValue(_ label: String, _ interval: TimeInterval) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      if nights.isEmpty {
        Text(isLoaded ? "No Data" : "–")
          .font(.system(.largeTitle, design: .rounded).bold())
          .foregroundStyle(.secondary)
      } else {
        SleepDurationText(interval)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The night or nights shown: "Oct 15, 2026", or "Oct 9 – 15, 2026".
  private var span: String {
    let (first, last) = days
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    guard first < last else { return last.formatted(style.month(.abbreviated).day().year()) }
    return (first..<last).formatted(
      Date.IntervalFormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone))
  }

  // MARK: Chart

  @ViewBuilder private var chartArea: some View {
    switch state {
    case .loading:
      // Its space, under the spinner `delayedProgress` shows (851-3086).
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let reason):
      ContentUnavailableView(
        "Couldn't Load Sleep", systemImage: "exclamationmark.triangle",
        description: Text(reason)
      )
      // A form's row would otherwise give it only its ideal width, off center.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Never any sleep: where it comes from. A period without sleep, when there's some
    // elsewhere, shows its chart empty, as Health does, under the header's No Data (851-3102).
    case .loaded(let period, _) where !period.hasSleep:
      ContentUnavailableView(
        "No Sleep Data", systemImage: "bed.double",
        description: Text("Sleep tracked by your Apple Watch or iPhone will appear here.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let period, _):
      Group {
        switch period.range {
        case .day:
          if let night = period.nights.last {
            stagesChart(night)
          } else {
            emptyNightChart(period.lastDay)
          }
        case .week, .month:
          SleepNightsChart(period: period, calendar: calendar)
        case .sixMonths:
          SleepWeeksChart(period: period, calendar: calendar)
        }
      }
      .emptyChartAccessibility(period.nights.isEmpty, label: ChartFormat.noData(span))
    }
  }

  /// The night's stages over time, a row each, as in Health.
  private func stagesChart(_ night: SleepNight) -> some View {
    stagesChart(night.segments, rows: SleepFormat.rows(for: night))
  }

  /// A day without a night (851-3102): the rows of the stages a Watch records, empty, over the
  /// hours a night usually takes (`SleepClock.axis`'s without times, 10 PM to 8 AM), so the
  /// chart keeps its axes and gridlines under the header's No Data.
  private func emptyNightChart(_ day: Date) -> some View {
    let hours = SleepClock.axis([]).domain
    let start = clockTime(hours.lowerBound, from: day)
    let end = clockTime(hours.upperBound, from: day)
    return stagesChart([], rows: [.awake, .rem, .core, .deep])
      .chartXScale(domain: start...end)
  }

  /// The time the clock reads `hours` from the start of `day` (-2 is 10 PM the evening before),
  /// so a daylight saving change doesn't move the empty night's ends.
  private func clockTime(_ hours: Double, from day: Date) -> Date {
    let days = Int((hours / 24).rounded(.down))
    let hour = Int(hours) - days * 24
    return calendar.date(byAdding: .day, value: days, to: day)
      .flatMap { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: $0) }
      ?? day.addingTimeInterval(hours * 3600)
  }

  /// Stages over time, a row each (`SleepStagesChart`).
  private func stagesChart(_ segments: [SleepSegment], rows: [SleepStage]) -> some View {
    SleepStagesChart(segments: segments, rows: rows)
  }

  // MARK: Stages

  /// Health's stages without times, where a night's go while it loads: the rows a Watch's night
  /// has, so loading one moves nothing (851-3084). A night without stages has two rows (Awake and
  /// Asleep), and one with unspecified sleep too five, so those still move what's below by a row
  /// or two when they arrive: which a night has can't be known before it loads.
  private var stagesPlaceholder: some View {
    Section("Stages") {
      ForEach([SleepStage.awake, .rem, .core, .deep], id: \.self) { stage in
        HStack {
          Circle()
            .fill(SleepFormat.color(stage))
            .frame(width: 10, height: 10)
          Text(SleepFormat.name(stage))
          Spacer()
          Text("–")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text("")
            .frame(width: 44, alignment: .trailing)
        }
      }
    }
  }

  /// Each stage's time and share of the night's sleep, a row each.
  private func stages(_ night: SleepNight) -> some View {
    let durations = night.durations
    let asleep = max(night.asleep, 1)
    return Section("Stages") {
      ForEach(SleepFormat.rows(for: night), id: \.self) { stage in
        let duration = durations[stage] ?? 0
        HStack {
          Circle()
            .fill(SleepFormat.color(stage))
            .frame(width: 10, height: 10)
          Text(SleepFormat.name(stage))
          Spacer()
          Text(SleepFormat.duration(duration))
            .foregroundStyle(.secondary)
          // Empty for Awake, which isn't sleep. A text either way, so every row's time lines up:
          // a `Spacer` here took no spacing beside it, and moved Awake's 8 pt right.
          Text(
            stage.isAsleep
              ? (duration / asleep).formatted(.percent.precision(.fractionLength(0))) : ""
          )
          .foregroundStyle(.secondary)
          .frame(width: 44, alignment: .trailing)
        }
      }
    }
  }
}

/// How sleep reads and looks.
enum SleepFormat {
  /// The chart's rows, top to bottom: Health's order for stages, or Awake and Asleep for a
  /// source that didn't record stages.
  static func rows(for night: SleepNight) -> [SleepStage] {
    guard night.hasStages else { return [.awake, .asleep] }
    // Asleep (unspecified) joins the stages if a staged night has some too, so it all shows.
    let unspecified = night.segments.contains { $0.stage == .asleep }
    return [.awake, .rem, .core, .deep] + (unspecified ? [.asleep] : [])
  }

  static func name(_ stage: SleepStage) -> String {
    switch stage {
    case .inBed: "In Bed"
    case .asleep: "Asleep"
    case .awake: "Awake"
    case .core: "Core"
    case .deep: "Deep"
    case .rem: "REM"
    }
  }

  static func color(_ stage: SleepStage) -> Color {
    switch stage {
    case .inBed: .gray
    case .asleep: .teal
    case .awake: Color(red: 1, green: 0.45, blue: 0.35)
    case .rem: .cyan
    case .core: .blue
    case .deep: .indigo
    }
  }

  /// "7 hr 32 min", "45 min".
  static func duration(_ interval: TimeInterval) -> String {
    durationParts(interval).map { "\($0.number) \($0.unit)" }.joined(separator: " ")
  }

  /// A duration's numbers and units: 7 and "hr", 32 and "min".
  static func durationParts(_ interval: TimeInterval) -> [(number: Int, unit: String)] {
    let minutes = Int((interval / 60).rounded())
    let (hours, rest) = (minutes / 60, minutes % 60)
    if hours == 0 { return [(rest, "min")] }
    return rest == 0 ? [(hours, "hr")] : [(hours, "hr"), (rest, "min")]
  }
}

/// A duration as Health's Sleep header writes it: big numbers, smaller units ("7 hr 46 min").
struct SleepDurationText: View {
  let interval: TimeInterval

  init(_ interval: TimeInterval) {
    self.interval = interval
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 3) {
      ForEach(Array(SleepFormat.durationParts(interval).enumerated()), id: \.offset) { _, part in
        Text("\(part.number)")
          .font(.system(.largeTitle, design: .rounded).bold())
        Text(part.unit)
          .font(.system(.title3, design: .rounded).weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.trailing, 3)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(SleepFormat.duration(interval))
  }
}
