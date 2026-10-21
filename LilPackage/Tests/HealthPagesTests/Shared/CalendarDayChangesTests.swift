import Combine
import Foundation
import HealthPages
import Testing

struct CalendarDayChangesTests {
  /// Foundation may post `NSCalendarDayChanged` on any thread; views update state from it, so it
  /// must arrive on the main thread (AGENTS.md, Objective-C callbacks).
  @Test
  func dayChangesArriveOnTheMainThread() async {
    await withCheckedContinuation { done in
      var subscription: AnyCancellable?
      subscription = calendarDayChanges().sink {
        #expect(Thread.isMainThread)
        subscription?.cancel()
        done.resume()
      }
      DispatchQueue(label: "test.day-change").async {
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
      }
    }
  }
}
