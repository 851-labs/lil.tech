import ComposableArchitecture
import Foundation

@testable import MessagesThread

extension MessageThreadViewController {
  /// The thread's view controller, with timestamps and read receipts relative to a fixed "now",
  /// which it reads from dependencies.
  @MainActor
  static func forTesting(store: StoreOf<MessageThreadFeature>) -> MessageThreadViewController {
    withDependencies {
      $0.date.now = Date(timeIntervalSinceReferenceDate: 800_000_000)
      $0.calendar = Calendar(identifier: .gregorian)
      $0.locale = Locale(identifier: "en_US")
    } operation: {
      MessageThreadViewController(store: store)
    }
  }
}
