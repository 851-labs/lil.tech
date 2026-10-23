import Dependencies
import HealthDatabase
import HealthUI
import SQLiteData
public import SwiftUI

/// Cycle Tracking, as in Health: a month's calendar of periods, spotting, ovulation tests,
/// symptoms and sexual activity, the factors going on now and past ones, the menopause stage, the
/// cycle deviations Health flagged, and past cycles' lengths. Health's predictions stay on the
/// iPhone (HealthKit doesn't share them), so there are none here. Follows the local database as
/// sync changes it, and the clock as factors, stages and deviations start, and factors and
/// stages end.
public struct CycleTrackingView: View {
  /// The type it was opened for, whose latest sample's month and day it opens on (851-2830).
  let typeID: String?
  @Dependency(\.defaultDatabase) private var database
  @Dependency(\.continuousClock) private var clock
  @State private var monthOffset = 0
  @State private var selected: Date?
  /// Whether the month to open on is known, so the first month loaded is the right one.
  @State private var isPositioned: Bool
  /// Moves at midnight, so the months do even if nothing syncs.
  @State private var today = Date.now
  /// When factors, the menopause stage and deviations are worked out for: moved on at midnight,
  /// and when one starts (or a factor or stage ends).
  @State private var historyNow = Date.now
  /// The last month loaded. While another loads, the page keeps showing it (851-3090).
  @Fetch private var days: CycleMonth? = nil
  /// Not tied to the month shown.
  @Fetch private var history: CycleHistory? = nil

  public init(typeID: String? = nil) {
    self.typeID = typeID
    // A period opens on today's month, as it always has: its latest sample may be "no flow".
    _isPositioned = State(initialValue: typeID == nil || typeID == HealthDatabase.menstrualFlowType)
  }

  public var body: some View {
    let month = ChartRange.month.interval(offset: monthOffset, now: today, calendar: .current)
    CycleTrackingContent(
      month: month, selected: $selected,
      state: ($days.loadError ?? $history.loadError).map { .failed($0.localizedDescription) }
        ?? {
          guard let days, let history else { return .loading }
          // The month loaded last, until the one chosen replaces it.
          return .loaded(
            CycleSnapshot(
              month: days.month, days: days.days, periods: history.periods,
              factors: history.factors, pastFactors: history.pastFactors,
              morePastFactors: history.morePastFactors, menopause: history.menopause,
              deviations: history.deviations, moreDeviations: history.moreDeviations),
            isUpdating: $days.isLoading || $history.isLoading || days.month != month)
        }(),
      // Not before the month to open on is known, which would move it from under the arrows.
      previous: { if isPositioned { monthOffset -= 1 } },
      next: { if isPositioned { monthOffset += 1 } },
      isLatest: monthOffset >= 0, now: today
    )
    .task(id: [String(monthOffset), today.formatted(.iso8601)]) {
      if !isPositioned {
        let offset = monthOffset
        await openOnLatestSample()
        isPositioned = true
        // A new month runs this task again for it.
        guard monthOffset == offset else { return }
      }
      let month = ChartRange.month.interval(offset: monthOffset, now: today, calendar: .current)
      _ = try? await $days.load(CycleMonthRequest(month: month), scheduler: MainQueueScheduler())
    }
    .task(id: historyNow) {
      _ = try? await $history.load(
        CycleHistoryRequest(now: historyNow), scheduler: MainQueueScheduler())
    }
    // Waits for the next factor, stage or deviation to start (or factor or stage to end), then
    // works them out again.
    .task(id: history?.nextChange) {
      guard let next = history?.nextChange else { return }
      do {
        try await clock.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0)))
      } catch {
        return
      }
      // Not before it: the clock can wake a little early, and the same change would come back.
      historyNow = max(.now, next)
    }
    .onReceive(calendarDayChanges()) {
      today = .now
      historyNow = .now
    }
  }

  /// Shows the month of the type's latest sample (not one dated later than now), with its day
  /// selected. Today's month if it has none.
  private func openOnLatestSample() async {
    let now = Date.now
    guard let typeID,
      let latest = try? await database.read({ db in
        try HealthDatabase.latestSample(of: typeID, startedBy: now, db)?.start
      })
    else { return }
    let calendar = Calendar.current
    let thisMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
    let month = calendar.dateInterval(of: .month, for: latest)?.start ?? latest
    monthOffset = min(calendar.dateComponents([.month], from: thisMonth, to: month).month ?? 0, 0)
    selected = calendar.startOfDay(for: latest)
  }
}

/// A month's days, with the periods, factors, menopause stage and deviations around it.
struct CycleSnapshot: Equatable, Sendable {
  var month: DateInterval
  var days: [Date: CycleDay]
  var periods: [Period]
  /// Going on now.
  var factors: [CycleFactor]
  /// Over, the latest to end first.
  var pastFactors: [CycleFactor] = []
  /// Whether there are more past factors than the page shows.
  var morePastFactors = false
  var menopause: MenopauseStage?
  /// Newest first.
  var deviations: [CycleDeviation] = []
  /// Whether there are more deviations than the page shows.
  var moreDeviations = false

  /// Whether there's nothing to show at all, not just this month.
  var isEmpty: Bool {
    days.isEmpty && periods.isEmpty && factors.isEmpty && pastFactors.isEmpty && menopause == nil
      && deviations.isEmpty
  }
}

struct CycleMonth: Equatable, Sendable {
  var month: DateInterval
  var days: [Date: CycleDay]
}

struct CycleMonthRequest: FetchKeyRequest {
  let month: DateInterval

  func fetch(_ db: Database) throws -> CycleMonth? {
    CycleMonth(month: month, days: try HealthDatabase.cycleDays(in: month, calendar: .current, db))
  }
}

struct CycleHistory: Equatable, Sendable {
  var periods: [Period]
  var factors: [CycleFactor]
  var pastFactors: [CycleFactor]
  var morePastFactors: Bool
  var menopause: MenopauseStage?
  var deviations: [CycleDeviation]
  var moreDeviations: Bool
  /// When a factor, stage or deviation next starts, or a factor or stage ends, to work them out
  /// again then.
  var nextChange: Date?
}

/// Periods, and factors, the menopause stage and deviations as they are at `now`.
struct CycleHistoryRequest: FetchKeyRequest {
  /// Past factors shown at most: years of them.
  static let pastFactorLimit = 20
  /// Deviations shown at most: years of them, as Health flags a few a year at most.
  static let deviationLimit = 20

  let now: Date

  func fetch(_ db: Database) throws -> CycleHistory? {
    // One more than shown, to know whether there are more.
    let pastFactors = try HealthDatabase.cycleFactorHistory(
      before: now, limit: Self.pastFactorLimit + 1, db)
    let deviations = try HealthDatabase.cycleDeviations(
      startedBy: now, limit: Self.deviationLimit + 1, db)
    return CycleHistory(
      periods: try HealthDatabase.periods(limit: 12, calendar: .current, db),
      factors: try HealthDatabase.cycleFactors(at: now, db),
      pastFactors: Array(pastFactors.prefix(Self.pastFactorLimit)),
      morePastFactors: pastFactors.count > Self.pastFactorLimit,
      menopause: try HealthDatabase.menopauseStage(at: now, db),
      deviations: Array(deviations.prefix(Self.deviationLimit)),
      moreDeviations: deviations.count > Self.deviationLimit,
      nextChange: try HealthDatabase.nextCycleChange(after: now, db))
  }
}

/// What Cycle Tracking shows, however it got it.
struct CycleTrackingContent: View {
  enum State {
    /// Nothing to show yet: the month's calendar without marks, in its loaded place (851-3090).
    case loading
    /// A month and what's around it. Updating while another month, or the same one again, loads:
    /// it stays on screen, with a spinner by the month's name, rather than the page blanking.
    case loaded(CycleSnapshot, isUpdating: Bool = false)
    case failed(String)
  }

  /// The month chosen with the arrows, which can be ahead of the one shown (`month`).
  let selectedMonth: DateInterval
  @Binding var selected: Date?
  let state: State
  var previous: () -> Void = {}
  var next: () -> Void = {}
  var isLatest = true
  /// Today, as the page has it: marked, and shown when nothing's selected.
  let now: Date
  /// From dependencies, so snapshot catalogs fix it (`previewCalendar`).
  @Dependency(\.calendar) private var calendar
  /// The calendar's day with keyboard focus, if it has it.
  @FocusState private var focusedDay: Date?
  /// The calendar's day that can take focus (`calendarDay`).
  @State private var focusTarget: Date?

  init(
    month: DateInterval, selected: Binding<Date?>, state: State,
    previous: @escaping () -> Void = {}, next: @escaping () -> Void = {}, isLatest: Bool = true,
    now: Date
  ) {
    selectedMonth = month
    _selected = selected
    self.state = state
    self.previous = previous
    self.next = next
    self.isLatest = isLatest
    self.now = now
  }

  /// The month shown: the loaded one, which stays while another loads, or the one chosen before
  /// any has loaded. Everything drawn uses it.
  private var month: DateInterval {
    if case .loaded(let snapshot, _) = state { snapshot.month } else { selectedMonth }
  }

  /// The loaded month, or the chosen one without marks while there's none.
  private var shownSnapshot: CycleSnapshot {
    if case .loaded(let snapshot, _) = state { return snapshot }
    return CycleSnapshot(month: month, days: [:], periods: [], factors: [])
  }

  private var isUpdating: Bool {
    switch state {
    case .loading: true
    case .loaded(_, let isUpdating): isUpdating
    case .failed: false
    }
  }

  var body: some View {
    // A grouped form on its own background, as Metric Detail is (851-2989, 851-3002): the
    // month's calendar, the day shown, then factors, deviations and past cycles, a section each.
    // The calendar's always there, loading, loaded or not, so other months can be reached, and
    // it keeps its place (851-3090).
    Form {
      Section {
        monthCalendar(shownSnapshot)
          .padding(.vertical, 6)
      }
      switch state {
      case .loading:
        EmptyView()
      case .failed(let reason):
        Section {
          ContentUnavailableView(
            "Couldn't Load Cycle Tracking", systemImage: "exclamationmark.triangle",
            description: Text(reason)
          )
          .frame(maxWidth: .infinity)
        }
      case .loaded(let snapshot, _):
        if snapshot.isEmpty {
          Section {
            ContentUnavailableView(
              "No Cycle Data", systemImage: "drop",
              description: Text(
                "Periods and symptoms you log in Cycle Tracking will appear here.")
            )
            // A form's row would otherwise give it only its ideal width, off center.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        } else {
          dayDetail(snapshot)
          if !snapshot.factors.isEmpty {
            factors("Factors", snapshot.factors)
          }
          if let stage = snapshot.menopause {
            menopause(stage)
          }
          if !snapshot.deviations.isEmpty {
            deviations(
              snapshot.deviations,
              more: snapshot.moreDeviations
                ? moreNote(CycleHistoryRequest.deviationLimit, "cycle deviations") : nil)
          }
          if !snapshot.pastFactors.isEmpty {
            factors(
              "Past Factors", snapshot.pastFactors,
              more: snapshot.morePastFactors
                ? moreNote(CycleHistoryRequest.pastFactorLimit, "past factors") : nil)
          }
          history(snapshot.periods)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Cycle Tracking")
  }

  // MARK: Calendar

  /// The month, its arrows, its days and what their marks mean, in one row.
  private func monthCalendar(_ snapshot: CycleSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(month.start.formatted(.dateTime.month(.wide).year()))
          .font(.title2.bold())
        // While a month loads.
        UpdatingSlot(isUpdating)
        Spacer()
        Button(action: previous) { Image(systemName: "chevron.left") }
          .accessibilityLabel("Earlier")
        Button(action: next) { Image(systemName: "chevron.right") }
          .accessibilityLabel("Later")
          .disabled(isLatest)
      }
      .buttonStyle(.borderless)
      let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
      let shown = shownDay
      LazyVGrid(columns: columns, spacing: 6) {
        ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
          Text(symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
          if let day {
            let isToday = calendar.isDate(day, inSameDayAs: now)
            CycleDayCell(
              day: day, entry: snapshot.days[day], isSelected: day == shown, isToday: isToday,
              calendar: calendar
            )
            // For the keyboard and VoiceOver too (851-3015).
            .calendarDay(
              day,
              label: MonthCalendar.label(
                day, isToday: isToday, details: CycleDayCell.logged(snapshot.days[day]),
                calendar: calendar),
              in: month, shown: shown, focus: $focusedDay,
              focusTarget: $focusTarget,
              calendar: calendar
            ) { selected = day }
          } else {
            // A day's cell, hidden, so a week of blanks is as tall as a week of days (851-3090).
            CycleDayCell(
              day: month.start, entry: nil, isSelected: false, isToday: false, calendar: calendar
            )
            .hidden()
          }
        }
      }
      legend
        // The calendar's end: what's below starts here, loading or not.
        .layoutAnchor("Legend")
    }
  }

  /// The weekday initials, starting on the calendar's first weekday.
  private var weekdaySymbols: [String] {
    let symbols = calendar.veryShortStandaloneWeekdaySymbols
    let first = calendar.firstWeekday - 1
    return Array(symbols[first...] + symbols[..<first])
  }

  /// The month's days, with blanks before the first to line it up with its weekday, and after
  /// the last to make six weeks.
  private var cells: [Date?] {
    MonthCalendar.cells(of: month, calendar: calendar)
  }

  private var legend: some View {
    HStack(spacing: 14) {
      legendItem("Period") { Circle().fill(.red) }
      legendItem("Spotting") { Circle().strokeBorder(.red, lineWidth: 1.5) }
      legendItem("Ovulation Test") { Circle().fill(.blue) }
      legendItem("Symptoms and Logs") { Circle().fill(.purple) }
      legendItem("Sexual Activity") { Circle().fill(.pink) }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  /// A mark and its name, close together: a form row spaces a `Label`'s icon as a row's icon.
  private func legendItem(_ name: String, @ViewBuilder mark: () -> some View) -> some View {
    HStack(spacing: 6) {
      mark().frame(width: 8, height: 8)
        .accessibilityHidden(true)
      Text(name)
    }
  }

  // MARK: Details

  /// The selected day, or today if it's in the month, or the month's first.
  private var shownDay: Date {
    if let selected, isInMonth(selected) { return selected }
    let today = calendar.startOfDay(for: now)
    return isInMonth(today) ? today : month.start
  }

  /// In the month: `DateInterval.contains` also counts its end, the next month's first instant.
  private func isInMonth(_ date: Date) -> Bool { date >= month.start && date < month.end }

  /// What the day shown has logged, a row each, under its date.
  private func dayDetail(_ snapshot: CycleSnapshot) -> some View {
    let entry = snapshot.days[shownDay]
    return Section {
      if let entry, entry != CycleDay() {
        if let flow = entry.flow { Text(flow.name) }
        if entry.spotting { Text("Spotting") }
        if entry.sexualActivity { Text("Sexual Activity") }
        // Each as Health names it: Cervical Mucus Quality, and Egg White on the right.
        ForEach(Array(entry.log.enumerated()), id: \.offset) { _, item in
          LabeledContent(item.name) {
            if let value = item.value { Text(value) }
          }
        }
        if !entry.symptoms.isEmpty {
          Text(entry.symptoms.joined(separator: ", "))
            .foregroundStyle(.purple)
        }
      } else {
        Text("Nothing Logged")
          .foregroundStyle(.secondary)
      }
    } header: {
      Text(shownDay.formatted(date: .complete, time: .omitted))
    }
  }

  /// Factors going on now, since when, or past ones, from when to when, with a note under them
  /// if there are more.
  private func factors(_ title: String, _ factors: [CycleFactor], more: Text? = nil) -> some View {
    Section {
      ForEach(Array(factors.enumerated()), id: \.offset) { _, factor in
        LabeledContent {
          if let end = factor.end {
            Text(CycleFormat.days(from: factor.start, to: end, calendar: calendar))
          } else {
            Text("Since \(factor.start.formatted(date: .abbreviated, time: .omitted))")
          }
        } label: {
          Text([factor.name, factor.detail].compactMap { $0 }.joined(separator: ": "))
        }
      }
    } header: {
      Text(title)
    } footer: {
      more
    }
  }

  /// Deviations Health flagged, over the months each covers (one day, if they start and end on
  /// it), with a note under them if there are more.
  private func deviations(_ deviations: [CycleDeviation], more: Text?) -> some View {
    Section {
      ForEach(Array(deviations.enumerated()), id: \.offset) { _, deviation in
        LabeledContent(deviation.name) {
          Text(CycleFormat.days(from: deviation.start, to: deviation.end, calendar: calendar))
        }
      }
    } header: {
      Text("Cycle Deviations")
    } footer: {
      more
    }
  }

  /// The stage last logged, and since when.
  private func menopause(_ stage: MenopauseStage) -> some View {
    Section("Menopause") {
      LabeledContent {
        Text("Since \(stage.since.formatted(.dateTime.month(.abbreviated).year()))")
      } label: {
        Text(stage.name ?? "Stage Logged")
      }
    }
  }

  /// Under a section that shows only the most recent `limit` of its `things`.
  private func moreNote(_ limit: Int, _ things: String) -> Text {
    Text("Showing the \(limit.formatted()) most recent \(things).")
  }

  /// Past periods, a row each: when, how long, and the cycle each started.
  private func history(_ periods: [Period]) -> some View {
    Section("Cycle History") {
      if periods.isEmpty {
        Text("No periods logged yet.")
          .foregroundStyle(.secondary)
      }
      ForEach(Array(periods.enumerated()), id: \.offset) { _, period in
        LabeledContent {
          Text(period.cycleLength.map { "Cycle: \($0) days" } ?? "Current Cycle")
        } label: {
          Text(
            "\(period.start.formatted(.dateTime.month(.abbreviated).day())) – \(period.end.formatted(.dateTime.month(.abbreviated).day().year()))"
          )
          Text("Period: \(period.length(calendar)) days")
        }
      }
    }
  }
}

/// How Cycle Tracking writes dates.
enum CycleFormat {
  /// The days a log covers, from `start` to `end`, as cycle deviations and past factors show them
  /// ("Mar 1 – 3, 2026", or one day). Its end is exclusive, so one at the very start of a day
  /// ends the range on the day before, unless it starts then too (851-2904). HealthKit may store
  /// a range's end as the following midnight or as its last day's end (23:59:59), and both read
  /// the same.
  static func days(
    from start: Date, to end: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent
  ) -> String {
    // The last moment inside, as `ChartFormat.span` has it. A range can't end before it starts.
    let last = max(start, end.addingTimeInterval(-1))
    return (start..<last).formatted(
      Date.IntervalFormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        .month(.abbreviated).day().year())
  }
}

/// A day in the calendar: its number on a red disc for a period (fuller for heavier flow), a
/// ring for spotting, and dots for ovulation tests, symptoms and sexual activity.
struct CycleDayCell: View {
  let day: Date
  let entry: CycleDay?
  let isSelected: Bool
  let isToday: Bool
  let calendar: Calendar

  var body: some View {
    VStack(spacing: 3) {
      Text("\(calendar.component(.day, from: day))")
        .font(.callout.weight(isToday ? .bold : .regular))
        .foregroundStyle(entry?.flow != nil ? .white : isToday ? .red : .primary)
        .frame(width: 30, height: 30)
        .background {
          if let flow = entry?.flow {
            Circle().fill(.red.opacity(opacity(flow)))
          } else if entry?.spotting == true || entry?.bleeding == true {
            Circle().strokeBorder(.red, lineWidth: 1.5)
          }
        }
        .overlay {
          if isSelected { Circle().strokeBorder(.primary.opacity(0.6), lineWidth: 2).padding(-3) }
        }
      HStack(spacing: 2) {
        if entry?.ovulationPositive == true { dot(.blue) }
        // Anything else logged, as Health's purple dot marks it.
        if entry?.symptoms.isEmpty == false || entry?.log.isEmpty == false { dot(.purple) }
        if entry?.sexualActivity == true { dot(.pink) }
      }
      .frame(height: 5)
    }
    .frame(maxWidth: .infinity, minHeight: 44)
    .contentShape(Rectangle())
  }

  /// What's logged on a day, for VoiceOver, as the day's section lists it.
  nonisolated static func logged(_ entry: CycleDay?) -> [String] {
    guard let entry else { return [] }
    var logged: [String] = []
    if let flow = entry.flow { logged.append(flow.name) }
    if entry.spotting { logged.append("Spotting") }
    if entry.sexualActivity { logged.append("Sexual Activity") }
    logged += entry.log.map { item in
      [item.name, item.value].compactMap { $0 }.joined(separator: ": ")
    }
    logged += entry.symptoms
    return logged
  }

  private func dot(_ color: Color) -> some View {
    Circle().fill(color).frame(width: 5, height: 5)
  }

  private func opacity(_ flow: MenstrualFlow) -> Double {
    switch flow {
    case .light: 0.55
    case .medium: 0.8
    case .heavy, .unspecified: 1
    case .none: 0
    }
  }
}
