import HealthDatabase
import SQLiteData
import SwiftUI

/// Cycle Tracking, as in Health: a month's calendar of periods, spotting, ovulation tests,
/// symptoms and sexual activity, the factors going on now, and past cycles' lengths. Health's
/// predictions stay on the iPhone (HealthKit doesn't share them), so there are none here.
/// Follows the local database as sync changes it.
struct CycleTrackingView: View {
  @State private var monthOffset = 0
  @State private var selected: Date?
  /// Moves at midnight, so the months do even if nothing syncs.
  @State private var today = Date.now
  @Fetch private var days: CycleMonth? = nil
  /// Not tied to the month shown, so they load once.
  @Fetch private var history: CycleHistory? = nil

  init() {
    _history = Fetch(wrappedValue: nil, CycleHistoryRequest(), scheduler: MainQueueScheduler())
  }

  var body: some View {
    let month = ChartRange.month.interval(offset: monthOffset, now: today, calendar: .current)
    CycleTrackingContent(
      month: month, selected: $selected,
      state: ($days.loadError ?? $history.loadError).map { .failed($0.localizedDescription) }
        // The month being loaded, not the one before it.
        ?? {
          guard let days, days.month == month, let history else { return .loading }
          return .loaded(
            CycleSnapshot(
              month: month, days: days.days, periods: history.periods,
              factors: history.factors))
        }(),
      previous: { monthOffset -= 1 }, next: { monthOffset += 1 },
      isLatest: monthOffset >= 0
    )
    .task(id: [String(monthOffset), today.formatted(.iso8601)]) {
      _ = try? await $days.load(CycleMonthRequest(month: month), scheduler: MainQueueScheduler())
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
      today = .now
    }
  }
}

/// A month's days, with the periods and factors around it.
struct CycleSnapshot: Equatable, Sendable {
  var month: DateInterval
  var days: [Date: CycleDay]
  var periods: [Period]
  var factors: [CycleFactor]

  /// Whether there's nothing to show at all, not just this month.
  var isEmpty: Bool { days.isEmpty && periods.isEmpty && factors.isEmpty }
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
}

struct CycleHistoryRequest: FetchKeyRequest {
  func fetch(_ db: Database) throws -> CycleHistory? {
    CycleHistory(
      periods: try HealthDatabase.periods(limit: 12, calendar: .current, db),
      factors: try HealthDatabase.cycleFactors(at: .now, db))
  }
}

/// What Cycle Tracking shows, however it got it.
struct CycleTrackingContent: View {
  enum State {
    case loading
    case loaded(CycleSnapshot)
    case failed(String)
  }

  let month: DateInterval
  @Binding var selected: Date?
  let state: State
  var previous: () -> Void = {}
  var next: () -> Void = {}
  var isLatest = true
  var calendar = Calendar.current

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load Cycle Tracking", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let snapshot):
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            // The calendar stays, so other months can be reached.
            calendarCard(snapshot)
            if snapshot.isEmpty {
              ContentUnavailableView(
                "No Cycle Data", systemImage: "drop",
                description: Text(
                  "Periods and symptoms you log in Cycle Tracking will appear here.")
              )
              .frame(maxWidth: .infinity)
            } else {
              dayDetail(snapshot)
              if !snapshot.factors.isEmpty {
                factors(snapshot.factors)
              }
              history(snapshot.periods)
            }
          }
          .padding(20)
          .frame(maxWidth: 760)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .navigationTitle("Cycle Tracking")
  }

  // MARK: Calendar

  private func calendarCard(_ snapshot: CycleSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(month.start.formatted(.dateTime.month(.wide).year()))
          .font(.title2.bold())
        Spacer()
        Button(action: previous) { Image(systemName: "chevron.left") }
          .accessibilityLabel("Earlier")
        Button(action: next) { Image(systemName: "chevron.right") }
          .accessibilityLabel("Later")
          .disabled(isLatest)
      }
      .buttonStyle(.borderless)
      let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
      LazyVGrid(columns: columns, spacing: 6) {
        ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
          Text(symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
          if let day {
            CycleDayCell(
              day: day, entry: snapshot.days[day], isSelected: day == shownDay,
              isToday: calendar.isDateInToday(day), calendar: calendar
            )
            .onTapGesture { selected = day }
          } else {
            Color.clear.frame(height: 44)
          }
        }
      }
      legend
    }
    .padding(16)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
  }

  /// The weekday initials, starting on the calendar's first weekday.
  private var weekdaySymbols: [String] {
    let symbols = calendar.veryShortStandaloneWeekdaySymbols
    let first = calendar.firstWeekday - 1
    return Array(symbols[first...] + symbols[..<first])
  }

  /// The month's days, with blanks before the first to line it up with its weekday.
  private var cells: [Date?] {
    var days: [Date?] = []
    let leading = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
    days.append(contentsOf: Array(repeating: nil, count: leading))
    var day = month.start
    while day < month.end {
      days.append(day)
      day = calendar.date(byAdding: .day, value: 1, to: day) ?? month.end
    }
    return days
  }

  private var legend: some View {
    HStack(spacing: 14) {
      legendItem("Period") { Circle().fill(.red) }
      legendItem("Spotting") { Circle().strokeBorder(.red, lineWidth: 1.5) }
      legendItem("Ovulation Test") { Circle().fill(.blue) }
      legendItem("Symptoms") { Circle().fill(.purple) }
      legendItem("Sexual Activity") { Circle().fill(.pink) }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func legendItem(_ name: String, @ViewBuilder mark: () -> some View) -> some View {
    Label {
      Text(name)
    } icon: {
      mark().frame(width: 8, height: 8)
    }
  }

  // MARK: Details

  /// The selected day, or today if it's in the month, or the month's first.
  private var shownDay: Date {
    if let selected, isInMonth(selected) { return selected }
    let today = calendar.startOfDay(for: .now)
    return isInMonth(today) ? today : month.start
  }

  /// In the month: `DateInterval.contains` also counts its end, the next month's first instant.
  private func isInMonth(_ date: Date) -> Bool { date >= month.start && date < month.end }

  private func dayDetail(_ snapshot: CycleSnapshot) -> some View {
    let entry = snapshot.days[shownDay]
    return VStack(alignment: .leading, spacing: 8) {
      Text(shownDay.formatted(date: .complete, time: .omitted))
        .font(.headline)
      if let entry, entry != CycleDay() {
        if let flow = entry.flow { Text(flow.name) }
        if entry.spotting { Text("Spotting") }
        if entry.ovulationPositive { Text("Positive Ovulation Test") }
        if entry.sexualActivity { Text("Sexual Activity") }
        if !entry.symptoms.isEmpty {
          Text(entry.symptoms.joined(separator: ", "))
            .foregroundStyle(.purple)
        }
      } else {
        Text("Nothing Logged")
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
  }

  private func factors(_ factors: [CycleFactor]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Factors")
        .font(.title3.bold())
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(factors.enumerated()), id: \.offset) { _, factor in
          LabeledContent {
            Text("Since \(factor.since.formatted(date: .abbreviated, time: .omitted))")
          } label: {
            Text([factor.name, factor.detail].compactMap { $0 }.joined(separator: ": "))
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private func history(_ periods: [Period]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Cycle History")
        .font(.title3.bold())
      VStack(alignment: .leading, spacing: 0) {
        if periods.isEmpty {
          Text("No periods logged yet.")
            .foregroundStyle(.secondary)
            .padding(16)
        }
        ForEach(Array(periods.enumerated()), id: \.offset) { index, period in
          if index > 0 { Divider().padding(.leading, 16) }
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(
                "\(period.start.formatted(.dateTime.month(.abbreviated).day())) – \(period.end.formatted(.dateTime.month(.abbreviated).day().year()))"
              )
              .font(.headline)
              Text("Period: \(period.length(calendar)) days")
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(period.cycleLength.map { "Cycle: \($0) days" } ?? "Current Cycle")
              .foregroundStyle(.secondary)
          }
          .padding(16)
        }
      }
      .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }
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
          } else if entry?.spotting == true {
            Circle().strokeBorder(.red, lineWidth: 1.5)
          }
        }
        .overlay {
          if isSelected { Circle().strokeBorder(.primary.opacity(0.6), lineWidth: 2).padding(-3) }
        }
      HStack(spacing: 2) {
        if entry?.ovulationPositive == true { dot(.blue) }
        if entry?.symptoms.isEmpty == false { dot(.purple) }
        if entry?.sexualActivity == true { dot(.pink) }
      }
      .frame(height: 5)
    }
    .frame(maxWidth: .infinity, minHeight: 44)
    .contentShape(Rectangle())
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
