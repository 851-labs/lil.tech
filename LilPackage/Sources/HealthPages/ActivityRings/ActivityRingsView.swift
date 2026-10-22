import Dependencies
import HealthDatabase
import HealthUI
import SQLiteData
public import SwiftUI

/// Activity Rings, as in Fitness's calendar (851-2834): a month of days with their rings, and the
/// selected day's rings large, with each ring's progress toward its goal. Opens on the month of
/// the latest day with rings, today's if it has any. Follows the local database as sync changes
/// it.
public struct ActivityRingsView: View {
  @Dependency(\.defaultDatabase) private var database
  @State private var monthOffset = 0
  @State private var selected: Date?
  /// Whether the month to open on is known, so the first month loaded is the right one.
  @State private var isPositioned = false
  /// Moves at midnight, so the month does too.
  @State private var today = Date.now
  @Fetch private var month: ActivityMonth? = nil

  public init() {}

  public var body: some View {
    let interval = ChartRange.month.interval(offset: monthOffset, now: today, calendar: .current)
    ActivityRingsContent(
      month: interval, selected: $selected,
      state: $month.loadError.map { .failed($0.localizedDescription) }
        ?? {
          // The month being loaded, not the one before it.
          guard let month, month.month == interval else { return .loading }
          return .loaded(month.days)
        }(),
      previous: { monthOffset -= 1 }, next: { monthOffset += 1 }, isLatest: monthOffset >= 0
    )
    .task(id: [String(monthOffset), today.formatted(.iso8601)]) {
      if !isPositioned {
        let offset = monthOffset
        await openOnLatestDay()
        isPositioned = true
        // A new month runs this task again for it.
        guard monthOffset == offset else { return }
      }
      let interval = ChartRange.month.interval(offset: monthOffset, now: today, calendar: .current)
      _ = try? await $month.load(
        ActivityMonthRequest(month: interval), scheduler: MainQueueScheduler())
    }
    .onReceive(calendarDayChanges()) {
      today = .now
    }
  }
}

extension ActivityRingsView {
  /// Shows the month of the latest day with rings, with that day selected, when it's before this
  /// month: the iPhone may not have synced lately.
  private func openOnLatestDay() async {
    let calendar = Calendar.current
    let now = Date.now
    guard
      let latest = try? await database.read({ db in
        try HealthDatabase.latestActivityDay(by: now, calendar: calendar, db)
      })
    else { return }
    let thisMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
    let month = calendar.dateInterval(of: .month, for: latest)?.start ?? latest
    let offset = calendar.dateComponents([.month], from: thisMonth, to: month).month ?? 0
    guard offset < 0 else { return }
    monthOffset = offset
    selected = latest
  }
}

struct ActivityMonth: Equatable, Sendable {
  var month: DateInterval
  var days: [String: ActivityDay]
}

struct ActivityMonthRequest: FetchKeyRequest {
  let month: DateInterval

  func fetch(_ db: Database) throws -> ActivityMonth? {
    ActivityMonth(
      month: month, days: try HealthDatabase.activityDays(in: month, calendar: .current, db))
  }
}

/// What Activity Rings shows, however it got it.
struct ActivityRingsContent: View {
  enum State {
    case loading
    case loaded([String: ActivityDay])
    case failed(String)
  }

  let month: DateInterval
  @Binding var selected: Date?
  let state: State
  var previous: () -> Void = {}
  var next: () -> Void = {}
  var isLatest = true
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`): today and
  /// the days to come look different.
  @Dependency(\.calendar) private var calendar
  @Dependency(\.date.now) private var now

  var body: some View {
    // A grouped form on its own background, as Metric Detail is (851-2989, 851-3003): the month,
    // then the day chosen in it.
    Form {
      Section {
        VStack(alignment: .leading, spacing: 12) {
          monthHeader
          switch state {
          // As tall as the month's grid, so the page keeps its shape while a month loads or fails,
          // and as wide as the row, rather than its ideal width, off center.
          case .loading:
            ProgressView()
              .frame(maxWidth: .infinity, minHeight: gridHeight)
          case .failed(let reason):
            ContentUnavailableView(
              "Couldn't Load Activity Rings", systemImage: "exclamationmark.triangle",
              description: Text(reason)
            )
            .frame(maxWidth: .infinity, minHeight: gridHeight)
          case .loaded(let days):
            calendarGrid(days)
          }
        }
        .padding(.vertical, 6)
      }
      if case .loaded(let days) = state {
        dayDetail(days[key(shownDay)])
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Activity Rings")
  }

  /// About the height of the month's grid: the weekdays, then a 54 pt line per week, 8 pt apart.
  private var gridHeight: CGFloat {
    let weeks = CGFloat((cells.count + 6) / 7)
    return 24 + weeks * 54 + (weeks - 1) * 8
  }

  // MARK: Calendar

  /// The month, and the buttons to the one before and after.
  private var monthHeader: some View {
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
  }

  @ViewBuilder private func calendarGrid(_ days: [String: ActivityDay]) -> some View {
    let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
        Text(symbol)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
        if let day {
          // A button, so the keyboard and VoiceOver can choose a day. Days to come have none.
          Button {
            selected = day
          } label: {
            ActivityDayCell(
              number: calendar.component(.day, from: day), day: days[key(day)],
              isSelected: day == shownDay, isToday: calendar.isDate(day, inSameDayAs: now),
              isFuture: day > calendar.startOfDay(for: now))
          }
          .buttonStyle(.plain)
          .disabled(day > calendar.startOfDay(for: now))
        } else {
          Color.clear.frame(height: 54)
        }
      }
    }
    if days.isEmpty {
      Text("No Activity rings this month.")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
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

  /// A day's summary key: its Gregorian `yyyy-MM-dd`, whatever the Mac's calendar.
  private func key(_ day: Date) -> String { ActivityDay.key(for: day, calendar: calendar) }

  // MARK: Day

  /// The selected day, or today if it's in the month, or the month's first.
  private var shownDay: Date {
    if let selected, selected >= month.start, selected < month.end { return selected }
    let today = calendar.startOfDay(for: now)
    return today >= month.start && today < month.end ? today : month.start
  }

  /// The day's rings large, beside each ring's progress toward its goal, under the day's date.
  private func dayDetail(_ day: ActivityDay?) -> some View {
    Section(shownDay.formatted(date: .complete, time: .omitted)) {
      if let day {
        HStack(alignment: .center, spacing: 24) {
          ActivityRings(day: day, lineWidth: 18)
            .frame(width: 150, height: 150)
          VStack(alignment: .leading, spacing: 10) {
            if day.isPaused {
              Label("Paused", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
            }
            ringRow(
              "Move", day.move, unit: day.movesInMinutes ? "min" : "kcal", color: ActivityRings.move
            )
            if let exercise = day.exercise {
              ringRow("Exercise", exercise, unit: "min", color: ActivityRings.exercise)
            }
            if let stand = day.stand {
              ringRow("Stand", stand, unit: "hr", color: ActivityRings.stand)
            }
          }
          Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
      } else {
        Text("No Activity Rings")
          .foregroundStyle(.secondary)
      }
    }
  }

  /// "Move 420/500 kcal", in the ring's color.
  private func ringRow(_ name: String, _ ring: ActivityRing, unit: String, color: Color)
    -> some View
  {
    VStack(alignment: .leading, spacing: 1) {
      Text(name)
        .font(.subheadline.weight(.semibold))
      Text("\(Self.number(ring.value))/\(Self.number(ring.goal)) \(unit)")
        .font(.system(.title2, design: .rounded).weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(color)
    }
  }

  private static func number(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0)))
  }
}

/// A day in the calendar: its number over its rings, small.
struct ActivityDayCell: View {
  let number: Int
  let day: ActivityDay?
  let isSelected: Bool
  let isToday: Bool
  /// A day to come, which has no rings yet.
  var isFuture = false

  var body: some View {
    VStack(spacing: 3) {
      Text("\(number)")
        .font(.caption.weight(isToday ? .bold : .regular))
        .foregroundStyle(isToday ? .red : .primary)
      Group {
        if let day {
          ActivityRings(day: day, lineWidth: 3.5)
        } else if isFuture {
          Color.clear
        } else {
          Circle()
            .strokeBorder(.quaternary, lineWidth: 3.5)
        }
      }
      .frame(width: 34, height: 34)
    }
    .padding(3)
    .frame(maxWidth: .infinity, minHeight: 54)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(.primary.opacity(0.5), lineWidth: 1.5)
      }
    }
    .contentShape(Rectangle())
  }
}

/// A day's rings, nested as Fitness draws them: Move outside, then Exercise and Stand when it has
/// them. Drawn in SwiftUI, since `HKActivityRingView` isn't on the Mac.
struct ActivityRings: View {
  let day: ActivityDay
  let lineWidth: CGFloat

  static let move = Color(red: 0.98, green: 0.07, blue: 0.31)
  static let exercise = Color(red: 0.57, green: 0.91, blue: 0.16)
  static let stand = Color(red: 0.12, green: 0.92, blue: 0.94)

  var body: some View {
    let rings = [(day.move, Self.move), (day.exercise, Self.exercise), (day.stand, Self.stand)]
      .compactMap { ring, color in ring.map { ($0, color) } }
    ZStack {
      ForEach(Array(rings.enumerated()), id: \.offset) { index, item in
        // A little gap between rings, in proportion, so small ones keep their holes.
        ActivityRingShape(progress: item.0.progress, color: item.1, lineWidth: lineWidth)
          .padding(CGFloat(index) * lineWidth * 1.2)
      }
    }
    .opacity(day.isPaused ? 0.45 : 1)
    .accessibilityElement()
    .accessibilityLabel(Self.description(day))
  }

  static func description(_ day: ActivityDay) -> String {
    var parts = ["Move \(Int(day.move.progress * 100))%"]
    if let exercise = day.exercise { parts.append("Exercise \(Int(exercise.progress * 100))%") }
    if let stand = day.stand { parts.append("Stand \(Int(stand.progress * 100))%") }
    if day.isPaused { parts.append("Paused") }
    return parts.joined(separator: ", ")
  }
}

/// One ring: a faint track, and the progress around it from the top. Past its goal it goes round
/// again, overlapping itself with a shadow at its end, as Fitness's rings do.
struct ActivityRingShape: View {
  let progress: Double
  let color: Color
  let lineWidth: CGFloat

  var body: some View {
    let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
    ZStack {
      Circle()
        .stroke(color.opacity(0.22), lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: min(progress, 1))
        .stroke(color, style: style)
      if progress > 1 {
        // The last lap past the goal, ending where the progress does (a whole lap at 200%).
        let lap = progress.truncatingRemainder(dividingBy: 1)
        let end = lap == 0 ? 1 : lap
        Circle()
          .trim(from: 0, to: end)
          .stroke(color, style: style)
        // Its end shadowed over the lap below it, as Fitness's are.
        Circle()
          .trim(from: max(end - 0.02, 0), to: end)
          .stroke(color, style: style)
          .shadow(color: .black.opacity(0.5), radius: lineWidth / 3)
      }
    }
    .rotationEffect(.degrees(-90))
    .padding(lineWidth / 2)
  }
}
