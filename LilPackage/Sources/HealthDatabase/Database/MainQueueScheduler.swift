public import Dependencies
import Foundation
public import GRDB

/// Fetches in the background and delivers on the main queue, even the first value, unless
/// `fetchesFirstValueAtOnce` is set where it's made.
public struct MainQueueScheduler: ValueObservationScheduler, Hashable {
  private let fetchesFirstValueAtOnce: Bool

  public init() {
    @Dependency(\.fetchesFirstValueAtOnce) var fetchesFirstValueAtOnce
    self.fetchesFirstValueAtOnce = fetchesFirstValueAtOnce
  }

  /// GRDB only allows `true` on the main thread.
  public func immediateInitialValue() -> Bool { fetchesFirstValueAtOnce && Thread.isMainThread }

  public func schedule(_ action: @escaping @Sendable () -> Void) {
    DispatchQueue.main.async(execute: action)
  }
}

extension DependencyValues {
  /// Whether `MainQueueScheduler`s fetch the first value at once, on the thread that starts the
  /// observation, rather than in the background (851-2952). Only for snapshot catalogs of whole
  /// windows: their test holds the main queue until the image is taken, so a page's first value
  /// would otherwise never arrive.
  public var fetchesFirstValueAtOnce: Bool {
    get { self[FetchesFirstValueAtOnceKey.self] }
    set { self[FetchesFirstValueAtOnceKey.self] = newValue }
  }
}

private enum FetchesFirstValueAtOnceKey: DependencyKey {
  static let liveValue = false
  static let testValue = false
}
