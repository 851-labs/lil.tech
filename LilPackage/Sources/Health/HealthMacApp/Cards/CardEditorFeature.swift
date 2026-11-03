public import ComposableArchitecture
import Foundation
public import HealthCards
import HealthCatalog
public import HealthDatabase

/// The card editor (851-3208, docs/decisions/cards.md, UI › Mac): a card's name, symbol and color,
/// for a new card or one of the account's, with a live preview of the card as the fields change,
/// and the validator's errors under the fields they're about.
///
/// Editing keeps the card's query (its series, formulas, bucket, range and chart) as it is: the
/// query builder (851-3209) edits it. A new card starts from a type picked for its one series,
/// with the type's defaults for everything else, as an agent writing only a type gets them. Until
/// the person changes them, its name, symbol and color follow the type: its name, and its
/// category's symbol and color.
///
/// Saving and deleting are `CardsFeature`'s writes, through ``Action/Delegate``: it closes the
/// editor once the write is made, or shows why it was refused.
@Reducer
public struct CardEditorFeature {
  @ObservableState
  public struct State: Equatable {
    /// The card edited, or `nil` for a new one.
    public let cardID: Card.ID?
    /// The edited card's spec as it was, whose query the editor keeps.
    public let original: CardSpec?
    public var name: String
    public var symbol: String
    public var color: CardColor
    /// A new card's one series' type, until one is picked `nil`.
    public var typeID: String?
    /// Whether the person chose these, so a new card's type no longer sets them.
    var isNameEdited = false
    var isSymbolChosen = false
    var isColorChosen = false
    /// The spec the fields make, when it's valid: what Save writes.
    public var spec: CardSpec?
    /// Why the fields don't make a valid spec, from `CardSpec(input:)`.
    public var errors: [CardSpecError] = []
    /// What the preview shows: the last valid spec, a moment after typing stops.
    public var preview: CardSpec?
    public var isSymbolPickerPresented = false
    /// Why saving was refused (`CardWriteError`): too many cards, or the card was deleted.
    public var saveError: String?
    /// Delete Card…'s confirmation.
    @Presents public var alert: AlertState<Action.Alert>?

    /// A new card, before its type is picked.
    public init(typeID: String? = nil) {
      cardID = nil
      original = nil
      name = ""
      symbol = Self.newCardSymbol
      color = Self.newCardColor
      if let typeID { self.typeChosen(typeID) }
      validate()
      preview = spec
    }

    /// Editing a card this version can read. `nil` for one of a later version.
    public init?(editing card: Card) {
      guard let spec = card.spec else { return nil }
      cardID = card.id
      original = spec
      name = spec.display.name
      symbol = spec.display.symbol
      color = spec.display.color
      validate()
      preview = self.spec
    }

    /// A new card's symbol and color before a type gives it its own.
    static let newCardSymbol = "chart.line.uptrend.xyaxis"
    static let newCardColor = CardColor.blue

    public var isNew: Bool { cardID == nil }

    /// Whether Save writes something: the fields make a valid spec that isn't the card's own.
    public var canSave: Bool {
      guard let spec else { return false }
      return spec != original
    }

    /// The spec the fields describe, as apps write one (`CardSpec(input:)` canonicalizes it), or
    /// `nil` for a new card without a type yet.
    var input: CardJSON? {
      let display: CardJSON = [
        "name": .string(name), "symbol": .string(symbol), "color": .string(color.rawValue),
        "unit": original?.display.unit.map(CardJSON.string) ?? .null,
      ]
      if let original {
        return original.json.replacing("display", with: display)
      }
      guard let typeID else { return nil }
      return [
        "version": .number(Double(HealthCards.specVersion)), "display": display,
        "series": [["type": .string(typeID)]],
      ]
    }

    mutating func validate() {
      guard let input else {
        spec = nil
        errors = []
        return
      }
      do {
        spec = try CardSpec(input: input)
        errors = []
      } catch {
        spec = nil
        errors = error.errors
      }
    }

    /// A new card's type: its name, symbol and color follow it until the person changes them.
    mutating func typeChosen(_ id: String) {
      typeID = id
      guard let type = HealthCatalog.type(id: id) else { return }
      if !isNameEdited { name = type.name }
      if !isSymbolChosen {
        symbol = type.category?.symbolName ?? Self.newCardSymbol
      }
      if !isColorChosen {
        color = type.category.flatMap { CardColor(rawValue: $0.colorName) } ?? Self.newCardColor
      }
    }

    /// The errors about a field of the display (`name`, `symbol`, `color`), as the editor words
    /// them: the validator's, which name the path for agents, with the field's name instead.
    public func errors(for field: Field) -> [String] {
      errors.filter { $0.field == field }.map { error in
        guard let label = field.label, error.message.hasPrefix(error.path) else {
          return error.message
        }
        return label + error.message.dropFirst(error.path.count)
      }
    }

    /// What a spec's errors are about, in the editor's sections.
    public enum Field: Equatable, Sendable {
      case name, symbol, color
      /// The query's, which this editor doesn't change: shown under Data.
      case query

      var label: String? {
        switch self {
        case .name: "Name"
        case .symbol: "Symbol"
        case .color: "Color"
        case .query: nil
        }
      }
    }
  }

  public enum Action: BindableAction {
    case alert(PresentationAction<Alert>)
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case colorChosen(CardColor)
    case deleteButtonTapped
    case delegate(Delegate)
    case nameChanged(String)
    /// Typing stopped long enough for the preview to follow.
    case previewDebounced
    case saveButtonTapped
    case symbolChosen(String)
    case typeChosen(String)

    @CasePathable
    public enum Alert: Equatable, Sendable {
      case confirmDelete
    }

    @CasePathable
    public enum Delegate: Equatable {
      /// Write the spec: a new card, or the edited one's.
      case save(CardSpec)
      /// Delete the edited card, confirmed.
      case delete
    }
  }

  enum CancelID { case preview }

  /// How long the preview waits after a keystroke, so it doesn't run the card on every one.
  static let previewDelay = Duration.milliseconds(300)

  @Dependency(\.continuousClock) var clock
  @Dependency(\.dismiss) var dismiss

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .nameChanged(let name):
        state.name = name
        state.isNameEdited = !name.isEmpty
        state.validate()
        // A name follows the keyboard: the preview, once typing stops.
        return .run { [clock] send in
          try await clock.sleep(for: Self.previewDelay)
          await send(.previewDebounced)
        }
        .cancellable(id: CancelID.preview, cancelInFlight: true)

      case .previewDebounced:
        if let spec = state.spec { state.preview = spec }
        return .none

      case .symbolChosen(let symbol):
        state.symbol = symbol
        state.isSymbolChosen = true
        state.isSymbolPickerPresented = false
        return updatePreview(&state)

      case .colorChosen(let color):
        state.color = color
        state.isColorChosen = true
        return updatePreview(&state)

      case .typeChosen(let id):
        guard state.isNew else { return .none }
        state.typeChosen(id)
        return updatePreview(&state)

      case .cancelButtonTapped:
        return .run { [dismiss] _ in await dismiss() }

      case .saveButtonTapped:
        guard let spec = state.spec, state.canSave else { return .none }
        state.saveError = nil
        return .send(.delegate(.save(spec)))

      case .deleteButtonTapped:
        guard let original = state.original else { return .none }
        state.alert = .confirmDelete(name: original.display.name)
        return .none

      case .alert(.presented(.confirmDelete)):
        return .send(.delegate(.delete))

      case .alert, .binding, .delegate:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  /// A choice shows in the preview at once: the fields' spec, when it's valid.
  private func updatePreview(_ state: inout State) -> Effect<Action> {
    state.validate()
    if let spec = state.spec { state.preview = spec }
    return .cancel(id: CancelID.preview)
  }
}

extension CardSpecError {
  /// The editor's field the error is about.
  var field: CardEditorFeature.State.Field {
    switch path {
    case "display.name": .name
    case "display.symbol": .symbol
    case "display.color": .color
    default: .query
    }
  }
}

extension CardJSON {
  /// This object with `key`'s member replaced, in its place, or added at the end.
  func replacing(_ key: String, with value: CardJSON) -> CardJSON {
    guard case .object(var members) = self else { return self }
    if let index = members.firstIndex(where: { $0.key == key }) {
      members[index].value = value
    } else {
      members.append((key, value))
    }
    return .object(members)
  }
}

extension AlertState where Action == CardEditorFeature.Action.Alert {
  /// Delete Card…'s confirmation, in the editor.
  static func confirmDelete(name: String) -> Self {
    Self {
      TextState("Delete “\(name)”?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDelete) { TextState("Delete") }
      ButtonState(role: .cancel) { TextState("Cancel") }
    } message: {
      TextState("It's deleted on all your devices.")
    }
  }
}
