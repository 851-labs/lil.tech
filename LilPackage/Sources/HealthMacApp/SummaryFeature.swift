public import ComposableArchitecture
public import Foundation
public import HealthCatalog
import HealthDatabase
import LilSync
import SQLiteData
import SwiftUI

extension SharedKey where Self == AppStorageKey<[String]>.Default {
  /// The data types pinned to Summary on this Mac before pins synced (851-2641). They're moved
  /// up to the account after its first sync, unless it has pins already, then cleared.
  static var summaryPins: Self {
    Self[.appStorage("summaryPins"), default: []]
  }
}

/// Summary's pinned metrics: pinning, unpinning and reordering them. Pins are synced
/// (`HealthPin`): they're read from the local table and written through ``SyncClient/push``,
/// shown at once.
@Reducer
public struct SummaryFeature {
  @ObservableState
  public struct State: Equatable {
    /// The pinned data types, in order, as last read or written.
    public var pins: [String]
    /// Whether the pins haven't been read yet, so an empty Summary would be wrong.
    public var isLoadingPins: Bool
    public var isEditing = false
    /// The editor's search for metrics to pin.
    public var search = ""

    /// Pins given, e.g. in previews, are shown at once; otherwise they're read (``Action/task``).
    public init(pins: [String]? = nil, isEditing: Bool = false) {
      self.pins = pins ?? []
      self.isLoadingPins = pins == nil
      self.isEditing = isEditing
    }

    /// The pins in order, each once.
    public var orderedPins: [String] {
      pins.reduce(into: []) { unique, id in
        if !unique.contains(id) { unique.append(id) }
      }
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
    case pinsLoaded([String])
    case pinsMoved(IndexSet, Int)
    case task
    case unpinButtonTapped(String)
  }

  @Dependency(\.defaultDatabase) var database
  @Dependency(\.sync) var sync

  public init() {}

  /// Shows `pins` at once, and writes them: locally now, to the server with the next sync.
  private func write(_ pins: [String], over old: [String]) -> Effect<Action> {
    .run { [sync] _ in
      do {
        try await sync.push(HealthDatabase.pinMutations(from: old, to: pins))
      } catch {
        reportIssue(error)
      }
    }
  }

  public var body: some ReducerOf<Self> {
    BindingReducer()
      .onChange(of: \.isEditing) { _, state in
        // However the editor closed (Done, Esc), it opens next time without a search.
        if !state.isEditing { state.search = "" }
        return .none
      }
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
        let old = state.orderedPins
        guard !old.contains(id) else { return .none }
        state.pins = old + [id]
        return write(state.pins, over: old)

      case .pinsLoaded(let pins):
        state.pins = pins
        state.isLoadingPins = false
        return .none

      case .pinsMoved(let source, let destination):
        // Offsets into what the editor shows: each pin once.
        let old = state.orderedPins
        var pins = old
        pins.move(fromOffsets: source, toOffset: destination)
        state.pins = pins
        return write(pins, over: old)

      case .task:
        // Changes from another Mac arrive with sync, as do this one's writes.
        return .run { [database] send in
          for try await pins in HealthDatabase.summaryPinUpdates(in: database) {
            await send(.pinsLoaded(pins))
          }
        } catch: { error, _ in
          reportIssue(error)
        }

      case .unpinButtonTapped(let id):
        let old = state.orderedPins
        state.pins = old.filter { $0 != id }
        return write(state.pins, over: old)
      }
    }
  }
}
