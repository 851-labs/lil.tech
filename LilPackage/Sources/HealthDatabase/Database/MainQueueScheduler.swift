import Foundation
public import GRDB

/// Fetches in the background and delivers on the main queue, even the first value.
public struct MainQueueScheduler: ValueObservationScheduler, Hashable {
  public init() {}

  public func immediateInitialValue() -> Bool { false }

  public func schedule(_ action: @escaping @Sendable () -> Void) {
    DispatchQueue.main.async(execute: action)
  }
}
