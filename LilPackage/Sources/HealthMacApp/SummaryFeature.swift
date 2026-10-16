public import ComposableArchitecture
public import Foundation
public import HealthCatalog
import SwiftUI

extension SharedKey where Self == FileStorageKey<[String]>.Default {
  /// The data types pinned to Summary, in order. Local to this Mac for now (851-2641), and
  /// cleared when the account signs out.
  static var summaryPins: Self {
    Self[
      .fileStorage(
        .applicationSupportDirectory.appending(
          path: "\(Bundle.main.bundleIdentifier ?? "tech.lil.health")/SummaryPins.json")),
      default: []]
  }
}

/// Summary's pinned metrics: pinning, unpinning and reordering them.
@Reducer
public struct SummaryFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.summaryPins) public var pins: [String]
    public var isEditing = false
    /// The editor's search for metrics to pin.
    public var search = ""

    public init(isEditing: Bool = false) {
      self.isEditing = isEditing
    }

    /// Metrics that can be pinned and aren't, matching the search, by name.
    public var unpinned: [HealthDataType] {
      let query = search.trimmingCharacters(in: .whitespaces)
      return Self.pinnable
        .filter {
          !pins.contains($0.id) && (query.isEmpty || $0.name.localizedStandardContains(query))
        }
    }

    /// What an empty Summary suggests: everyday metrics most iPhones record.
    public static let suggestions = [
      "HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierHeartRate",
      "HKQuantityTypeIdentifierActiveEnergyBurned",
      "HKQuantityTypeIdentifierDistanceWalkingRunning",
      "HKQuantityTypeIdentifierRestingHeartRate", "HKQuantityTypeIdentifierBodyMass",
    ]

    /// Types Browse lists, by name: Summary shows the same cards.
    static let pinnable = HealthCatalog.all
      .filter { $0.category != nil }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case doneButtonTapped
    case editButtonTapped
    case pinButtonTapped(String)
    case pinsMoved(IndexSet, Int)
    case unpinButtonTapped(String)
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .doneButtonTapped:
        state.isEditing = false
        state.search = ""
        return .none

      case .editButtonTapped:
        state.isEditing = true
        return .none

      case .pinButtonTapped(let id):
        state.$pins.withLock { pins in
          if !pins.contains(id) { pins.append(id) }
        }
        return .none

      case .pinsMoved(let source, let destination):
        state.$pins.withLock { $0.move(fromOffsets: source, toOffset: destination) }
        return .none

      case .unpinButtonTapped(let id):
        state.$pins.withLock { $0.removeAll { $0 == id } }
        return .none
      }
    }
  }
}
