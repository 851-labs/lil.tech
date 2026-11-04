public import ComposableArchitecture
import Foundation
public import HealthCardStore
public import HealthCards

// What each app's cards feature needs to present the editor (851-3213): the filters' choices from
// its own data, what Save writes over the card as it is now, and Delete…'s confirmation.

extension DependencyValues {
  /// The apps and device models a type's data came from, for a series' filter: each app sets its
  /// own on the editor, the Mac's from its database and the iPhone's from HealthKit.
  public var cardFilterChoices: CardFilterChoicesClient {
    get { self[CardFilterChoicesClient.self] }
    set { self[CardFilterChoicesClient.self] = newValue }
  }
}

public struct CardFilterChoicesClient: Sendable {
  public var load: @Sendable (_ type: String) async throws -> CardFilterChoices

  public init(load: @escaping @Sendable (_ type: String) async throws -> CardFilterChoices) {
    self.load = load
  }

  public func callAsFunction(_ type: String) async throws -> CardFilterChoices {
    try await load(type)
  }
}

extension CardFilterChoicesClient: TestDependencyKey {
  public static var testValue: Self {
    Self(load: unimplemented("CardFilterChoicesClient.load", placeholder: CardFilterChoices()))
  }
}

extension CardEditorFeature.State {
  /// What Save writes for `spec`, the editor's, over `current`, the card as it is now. A person
  /// who changed only the name, symbol or color writes them over the card's query as it is now,
  /// which another device or an agent may have changed while the editor was open. A query they
  /// changed is theirs, the last writer's (851-3209).
  public func written(_ spec: CardSpec, over current: CardSpec?) -> CardSpec {
    guard let original, spec.hasQuery(of: original), var edited = current else { return spec }
    edited.display.name = spec.display.name
    edited.display.symbol = spec.display.symbol
    edited.display.color = spec.display.color
    return edited
  }

  /// Whether closing the editor would lose something: a new card's type, name, symbol or color,
  /// or an edit.
  public var hasChanges: Bool {
    guard let original else {
      return !needsType || !name.isEmpty || isSymbolChosen || isColorChosen
    }
    return draft != original
  }
}

extension AlertState {
  /// Delete…'s confirmation, from the editor or a Summary row, which `delete` answers.
  public static func confirmDeleteCard(named name: String, _ delete: Action) -> Self {
    Self {
      TextState("Delete “\(name)”?")
    } actions: {
      ButtonState(role: .destructive, action: delete) { TextState("Delete") }
      ButtonState(role: .cancel) { TextState("Cancel") }
    } message: {
      TextState("It's deleted on all your devices.")
    }
  }

  /// A move that was refused, saying why.
  public static func cardNotMoved(_ error: CardWriteError) -> Self {
    Self {
      TextState("Couldn't Move the Card")
    } actions: {
      ButtonState(role: .cancel) { TextState("OK") }
    } message: {
      TextState(error.localizedDescription)
    }
  }
}
