public import ComposableArchitecture
import Foundation
public import HealthCardStore
public import HealthCards
public import HealthCatalog

/// The card editor (851-3208, 851-3209, docs/decisions/cards.md, UI): a card's name, symbol and
/// color, and the query builder writing the rest of its spec (series, chart and formulas), for a
/// new card or one of the account's, with a live preview of the card as the fields change, and the
/// validator's errors under the fields they're about. Both apps' (851-3213): each runs the preview
/// on its own engine, and gives the filters' choices (`cardFilterChoices`).
///
/// The fields are a draft spec (`draft`), which `CardSpec(input:)` validates after every change.
/// The builder offers only the choices the rules allow, given the rest of the draft (no Total for
/// heart rate, no Night without a sleep window), and a change that rules out another choice
/// changes that one too (`normalize()`): a sleep window turns an automatic bucket into Night, and
/// a range the new bucket doesn't have into its first. What's left to the validator (a name too
/// long, From and To the same time, every line hidden) shows under its field.
///
/// A new card starts with one series without a type, and nothing to save. Its first series' type
/// gives it its name, symbol and color, and its chart style, until the person chooses them.
///
/// Saving and deleting are `CardsFeature`'s writes, through ``Action/Delegate``: it closes the
/// editor once the write is made, or shows why it was refused.
@Reducer
public struct CardEditorFeature {
  @ObservableState
  public struct State: Equatable {
    /// The card edited, or `nil` for a new one.
    public let cardID: Card.ID?
    /// The edited card's spec as it was.
    public let original: CardSpec?
    /// The spec as the fields have it, valid or not. A new card's first series has an empty
    /// `type` until one is picked.
    public var draft: CardSpec
    /// Whether the person chose these, so a new card's first type no longer sets them.
    var isNameEdited = false
    var isSymbolChosen = false
    var isColorChosen = false
    var isStyleChosen = false
    /// The lead's value unit the goal is in, so a change of unit clears it.
    var goalUnit: CardValueUnit?
    /// The spec the fields make, when it's valid: what Save writes.
    public var spec: CardSpec?
    /// Why the fields don't make a valid spec, from `CardSpec(input:)`.
    public var errors: [CardSpecError] = []
    /// What the preview shows: the last valid spec, a moment after typing stops.
    public var preview: CardSpec?
    public var isSymbolPickerPresented = false
    /// The series whose type picker is open.
    public var typePickerSeries: String?
    /// The apps and devices each type's data came from, for the series' filters, once asked for.
    public var sources: [String: CardFilterChoices] = [:]
    /// Why saving was refused (`CardWriteError`): too many cards, or the card was deleted.
    public var saveError: String?
    /// Delete Card…'s confirmation.
    @Presents public var alert: AlertState<Action.Alert>?

    /// A new card, before its type is picked, or with `typeID` picked.
    public init(typeID: String? = nil) {
      cardID = nil
      original = nil
      draft = CardSpec(
        display: CardSpec.Display(name: "", symbol: Self.newCardSymbol, color: Self.newCardColor),
        series: [CardSpec.Series(id: "a", type: "", aggregation: .avg)], range: .week,
        chart: CardSpec.Chart(style: .line))
      goalUnit = draft.valueUnit
      if let typeID { typeChosen(typeID, series: "a") }
      validate()
      preview = spec
    }

    /// Editing a card this version can read. `nil` for one of a later version.
    public init?(editing card: Card) {
      guard let spec = card.spec else { return nil }
      cardID = card.id
      original = spec
      draft = spec
      goalUnit = spec.valueUnit
      isStyleChosen = true
      validate()
      preview = self.spec
    }

    /// A new card's symbol and color before a type gives it its own.
    static let newCardSymbol = "chart.line.uptrend.xyaxis"
    static let newCardColor = CardColor.blue

    public var isNew: Bool { cardID == nil }

    public var name: String {
      get { draft.display.name }
      set { draft.display.name = newValue }
    }
    public var symbol: String {
      get { draft.display.symbol }
      set { draft.display.symbol = newValue }
    }
    public var color: CardColor {
      get { draft.display.color }
      set { draft.display.color = newValue }
    }

    /// Whether a new card still needs its first series' type, without which there's no spec.
    public var needsType: Bool { draft.series.contains { $0.type.isEmpty } }

    /// Whether Save writes something: the fields make a valid spec that isn't the card's own.
    public var canSave: Bool {
      guard let spec else { return false }
      return spec != original
    }

    /// The spec the fields describe, as apps write one (`CardSpec(input:)` canonicalizes it), or
    /// `nil` for a new card without a type yet. A style the person hasn't chosen is left out, so
    /// it's the type's, as an agent writing only a type gets it.
    var input: CardJSON? {
      guard !needsType else { return nil }
      // A label of only spaces is no label: the type's name, or the formula's description.
      var draft = draft
      let isBlank = { (label: String?) in
        label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
      }
      for index in draft.series.indices where isBlank(draft.series[index].label) {
        draft.series[index].label = nil
      }
      for index in draft.formulas.indices where isBlank(draft.formulas[index].label) {
        draft.formulas[index].label = nil
      }
      let json = draft.json
      guard !isStyleChosen else { return json }
      return json.replacing(
        "chart", with: ["goal": draft.chart.goal.map { ["value": .number($0.value)] } ?? .null])
    }

    /// The spec the fields make now, and its errors. A save's refusal was about the fields as
    /// they were.
    mutating func validate() {
      saveError = nil
      guard let input else {
        spec = nil
        errors = []
        return
      }
      do {
        let spec = try CardSpec(input: input)
        self.spec = spec
        errors = []
        if !isStyleChosen { draft.chart.style = spec.chart.style }
      } catch {
        spec = nil
        errors = error.errors
      }
    }
  }

  public enum Action: BindableAction {
    case addFormulaButtonTapped(CardSpec.Formula.Kind)
    case addSeriesButtonTapped
    case alert(PresentationAction<Alert>)
    case binding(BindingAction<State>)
    case bucketChosen(CardSpec.Bucket)
    case cancelButtonTapped
    case colorChosen(CardColor)
    case deleteButtonTapped
    case delegate(Delegate)
    /// A formula's operands, points, label or visibility.
    case formulaChanged(CardSpec.Formula)
    case goalChanged(Double?)
    case nameChanged(String)
    /// Typing stopped long enough for the preview to follow.
    case previewDebounced
    case rangeChosen(CardRange)
    case removeFormulaButtonTapped(id: String)
    case removeSeriesButtonTapped(id: String)
    case saveButtonTapped
    /// A series' aggregation, window, filter, label or visibility.
    case seriesChanged(CardSpec.Series)
    /// A type's sources, for its series' filters.
    case sourcesLoaded(type: String, CardFilterChoices)
    /// A series' filter was shown: its type's apps and devices, unless they're loaded.
    case sourcesNeeded(type: String)
    case styleChosen(HealthDataType.ChartStyle)
    case symbolChosen(String)
    case typeChosen(series: String, type: String)
    case typePickerButtonTapped(series: String)
    case unitChosen(String?)

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

  /// How long the preview waits after a keystroke or a stepper's click, so it doesn't run the
  /// card on every one.
  static let previewDelay = Duration.milliseconds(300)

  @Dependency(\.continuousClock) var clock
  @Dependency(\.cardFilterChoices) var filterChoices
  @Dependency(\.dismiss) var dismiss

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .nameChanged(let name):
        state.name = name
        state.isNameEdited = !name.isEmpty
        return debouncePreview(&state)

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

      case .typePickerButtonTapped(let id):
        state.typePickerSeries = id
        return .none

      case .typeChosen(let id, let type):
        state.typePickerSeries = nil
        state.typeChosen(type, series: id)
        return updatePreview(&state)

      case .seriesChanged(let series):
        guard let index = state.draft.series.firstIndex(where: { $0.id == series.id }) else {
          return .none
        }
        let before = state.draft.series[index]
        state.draft.series[index] = series
        state.normalize()
        // Typing a label or stepping minutes reaches the preview once it stops.
        return before.isTyped(into: series) ? debouncePreview(&state) : updatePreview(&state)

      case .addSeriesButtonTapped:
        state.addSeries()
        return updatePreview(&state)

      case .removeSeriesButtonTapped(let id):
        state.removeSeries(id: id)
        return updatePreview(&state)

      case .bucketChosen(let bucket):
        state.draft.bucket = bucket
        state.normalize()
        return updatePreview(&state)

      case .rangeChosen(let range):
        state.draft.range = range
        return updatePreview(&state)

      case .styleChosen(let style):
        state.draft.chart.style = style
        state.isStyleChosen = true
        return updatePreview(&state)

      case .unitChosen(let unit):
        state.draft.display.unit = unit
        return updatePreview(&state)

      case .goalChanged(let value):
        state.draft.chart.goal = value.map(CardSpec.Goal.init(value:))
        state.goalUnit = state.draft.valueUnit
        return updatePreview(&state)

      case .addFormulaButtonTapped(let kind):
        state.addFormula(kind)
        return updatePreview(&state)

      case .formulaChanged(let formula):
        guard let index = state.draft.formulas.firstIndex(where: { $0.id == formula.id }) else {
          return .none
        }
        let before = state.draft.formulas[index]
        state.draft.formulas[index] = formula
        state.normalize()
        return before.isTyped(into: formula) ? debouncePreview(&state) : updatePreview(&state)

      case .removeFormulaButtonTapped(let id):
        state.draft.formulas.removeAll { $0.id == id }
        return updatePreview(&state)

      case .sourcesNeeded(let type):
        guard state.sources[type] == nil, !type.isEmpty else { return .none }
        return .run { [filterChoices] send in
          await send(.sourcesLoaded(type: type, try await filterChoices(type)))
        } catch: { _, _ in
          // Without them, the filter offers only what it has.
        }

      case .sourcesLoaded(let type, let sources):
        state.sources[type] = sources
        return .none

      case .cancelButtonTapped:
        return .run { [dismiss] _ in await dismiss() }

      case .saveButtonTapped:
        guard let spec = state.spec, state.canSave else { return .none }
        state.saveError = nil
        return .send(.delegate(.save(spec)))

      case .deleteButtonTapped:
        guard let original = state.original else { return .none }
        state.alert = .confirmDeleteCard(named: original.display.name, .confirmDelete)
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

  /// Typing reaches the preview once it stops; the errors follow every keystroke.
  private func debouncePreview(_ state: inout State) -> Effect<Action> {
    state.validate()
    return .run { [clock] send in
      try await clock.sleep(for: Self.previewDelay)
      await send(.previewDebounced)
    }
    .cancellable(id: CancelID.preview, cancelInFlight: true)
  }
}

extension CardSpec.Series {
  /// Whether `next` differs from this only in what's typed or stepped (its label, or a window's
  /// minutes), whose preview waits for the typing to stop.
  fileprivate func isTyped(into next: Self) -> Bool {
    var typed = next
    typed.label = label
    switch (window, next.window) {
    case (.beforeSleep, .beforeSleep): typed.window = window
    case (.afterWaking, .afterWaking): typed.window = window
    default: break
    }
    return typed == self && next != self
  }
}

extension CardSpec.Formula {
  /// Whether `next` differs from this only in its label or a moving average's points.
  fileprivate func isTyped(into next: Self) -> Bool {
    var typed = next
    typed.label = label
    if case .movingAverage(let of, _) = operation, case .movingAverage(of, _) = next.operation {
      typed.operation = operation
    }
    return typed == self && next != self
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
