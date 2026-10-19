import Combine
import Foundation

/// When the calendar day changes (at midnight, or when the clock or time zone changes), on the main
/// thread. Foundation doesn't say which thread posts `NSCalendarDayChanged`, and views update
/// their state from it, so it's delivered on the main queue (AGENTS.md, Objective-C callbacks).
func calendarDayChanges() -> some Publisher<Void, Never> {
  NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
    .map { _ in () }
    .receive(on: DispatchQueue.main)
}
