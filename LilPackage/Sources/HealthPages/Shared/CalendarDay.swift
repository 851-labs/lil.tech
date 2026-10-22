import SwiftUI

extension View {
  /// Makes a day in a month's calendar choosable without a pointer (851-3015). The calendar is one
  /// stop for Tab, as a date picker is: focus lands on the day shown, the arrow keys move it a day
  /// or a week within the month, and Space or Return chooses the focused day. VoiceOver reads the
  /// day as a button with `label`, selected when it's the day shown, and VO-Space chooses it. A
  /// click chooses it too.
  ///
  /// - Parameters:
  ///   - focus: The calendar's focused day, shared by its days.
  ///   - shown: The day shown, where focus lands.
  ///   - canChoose: Whether a day can be chosen. Focus skips the others.
  func calendarDay(
    _ day: Date, label: String, isSelected: Bool, in month: DateInterval, shown: Date,
    focus: FocusState<Date?>.Binding, calendar: Calendar,
    canChoose: @escaping (Date) -> Bool = { _ in true }, choose: @escaping () -> Void
  ) -> some View {
    modifier(
      CalendarDayModifier(
        day: day, label: label, isSelected: isSelected, month: month, shown: shown, focus: focus,
        calendar: calendar, canChoose: canChoose, choose: choose))
  }
}

private struct CalendarDayModifier: ViewModifier {
  let day: Date
  let label: String
  let isSelected: Bool
  let month: DateInterval
  let shown: Date
  let focus: FocusState<Date?>.Binding
  let calendar: Calendar
  let canChoose: (Date) -> Bool
  let choose: () -> Void
  @Environment(\.layoutDirection) private var layoutDirection

  func body(content: Content) -> some View {
    let isEnabled = canChoose(day)
    content
      // Only one day is focusable at a time, so Tab stops on the calendar once.
      .focusable(isEnabled && day == (focus.wrappedValue ?? shown))
      .focused(focus, equals: day)
      .onMoveCommand { direction in
        guard
          let next = MonthCalendar.day(
            moving: direction, from: day, in: month, layoutDirection: layoutDirection,
            calendar: calendar),
          canChoose(next)
        else { return }
        focus.wrappedValue = next
      }
      .onKeyPress(keys: [.space, .return]) { _ in
        choose()
        return .handled
      }
      .onTapGesture {
        guard isEnabled else { return }
        choose()
        // Focus follows a click while the calendar has it.
        if focus.wrappedValue != nil { focus.wrappedValue = day }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label)
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction {
        guard isEnabled else { return }
        choose()
      }
      .disabled(!isEnabled)
  }
}

/// How a month's calendar moves between days, and reads them.
enum MonthCalendar {
  /// The day an arrow key moves to from `day`: the day before or after (mirrored right to left,
  /// as the calendar is), or the same weekday a week before or after. Nil outside `month`.
  static func day(
    moving direction: MoveCommandDirection, from day: Date, in month: DateInterval,
    layoutDirection: LayoutDirection, calendar: Calendar
  ) -> Date? {
    let forward = layoutDirection == .rightToLeft ? -1 : 1
    let days =
      switch direction {
      case .left: -forward
      case .right: forward
      case .up: -7
      case .down: 7
      @unknown default: 0
      }
    guard days != 0, let next = calendar.date(byAdding: .day, value: days, to: day),
      next >= month.start, next < month.end
    else { return nil }
    return next
  }

  /// What VoiceOver reads for a day: its date, whether it's today, then `details`, such as what's
  /// logged on it ("Wednesday, March 4, 2026, Today, Light Flow, Cramps").
  static func label(
    _ day: Date, isToday: Bool, details: [String], calendar: Calendar,
    locale: Locale = .autoupdatingCurrent
  ) -> String {
    let date = day.formatted(
      Date.FormatStyle(
        date: .complete, time: .omitted, locale: locale, calendar: calendar,
        timeZone: calendar.timeZone))
    return ([date] + (isToday ? ["Today"] : []) + details).joined(separator: ", ")
  }
}
