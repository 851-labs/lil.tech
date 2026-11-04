public import ComposableArchitecture
public import HealthCards
public import HealthCatalog
public import HealthUI
public import SwiftUI

// The card editor (851-3208, docs/decisions/cards.md, UI): a sheet, a grouped form with the card's
// live preview at the top, then its name, symbol and color, the query builder's sections
// (851-3209), and Delete Card… for one of the account's cards. Cancel and Save are in the toolbar.
// Both apps' (851-3213): on the iPhone the symbols and types are pages the sheet pushes, the
// swatches a grid, and a refused save shows under the preview, where it's seen.

/// The card editor's sheet, with `preview` drawing the card for the spec the preview shows: each
/// app's runs it on its own engine, a catalog's gives its state. On the iPhone it's in a
/// `NavigationStack` of the sheet's, which its pickers push on.
public struct CardEditorView<Preview: View>: View {
  @Bindable var store: StoreOf<CardEditorFeature>
  @ViewBuilder let preview: (CardSpec?) -> Preview
  /// Where the iPhone's form starts scrolled to: its top in the app; a catalog's state shows a
  /// section further down, as a screen can't fit the form.
  var scrolledTo: CardEditorAnchor?

  public init(
    store: StoreOf<CardEditorFeature>, @ViewBuilder preview: @escaping (CardSpec?) -> Preview
  ) {
    self.init(store: store, scrolledTo: nil, preview: preview)
  }

  init(
    store: StoreOf<CardEditorFeature>, scrolledTo: CardEditorAnchor?,
    @ViewBuilder preview: @escaping (CardSpec?) -> Preview
  ) {
    self.store = store
    self.scrolledTo = scrolledTo
    self.preview = preview
  }

  /// The sheet's size in the Mac app.
  public static var width: CGFloat { 560 }
  public static var height: CGFloat { 700 }

  private var color: Color { Color(paletteName: store.color.rawValue) }

  public var body: some View {
    #if os(iOS)
      ScrollViewReader { proxy in
        form
          .onAppear {
            if let scrolledTo { proxy.scrollTo(scrolledTo, anchor: .top) }
          }
      }
    #else
      form
    #endif
  }

  private var form: some View {
    Form {
      Section {
        preview(store.preview)
          .padding(.vertical, 6)
      }
      #if os(iOS)
        saveError
      #endif
      Section {
        TextField("Name", text: $store.name.sending(\.nameChanged), prompt: namePrompt)
          // Below the preview, the fields keep their place, loaded or not (851-3084).
          .layoutAnchor("Name")
      } footer: {
        errors(store.state.errors(for: .name))
      }
      Section {
        #if os(iOS)
          NavigationLink {
            CardSymbolPage(selection: store.symbol, color: color) {
              store.send(.symbolChosen($0))
            }
          } label: {
            LabeledContent("Symbol") {
              Image(systemName: store.symbol)
                .foregroundStyle(color)
            }
          }
          CardColorSwatches(selection: store.color) { store.send(.colorChosen($0)) }
        #else
          LabeledContent("Symbol") {
            symbolButton
          }
          LabeledContent("Color") {
            CardColorSwatches(selection: store.color) { store.send(.colorChosen($0)) }
          }
        #endif
      } footer: {
        errors(store.state.errors(for: .symbol) + store.state.errors(for: .color))
      }
      // The query builder (851-3209): the series, the chart and the formulas.
      CardQueryBuilderSections(store: store)
      #if os(macOS)
        saveError
      #endif
      if !store.isNew {
        Section {
          Button("Delete Card…", role: .destructive) {
            store.send(.deleteButtonTapped)
          }
          .id(CardEditorAnchor.delete)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(store.isNew ? "New Card" : "Edit Card")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { store.send(.cancelButtonTapped) }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { store.send(.saveButtonTapped) }
          .disabled(!store.canSave)
      }
    }
    .alert($store.scope(\.alert, action: \.alert))
  }

  /// A new card's name says what it's for; on the iPhone, whose fields have no labels, an
  /// existing card's says it's the name.
  private var namePrompt: Text {
    #if os(iOS)
      Text(store.isNew ? "What Summary calls it" : "Name")
    #else
      Text(store.isNew ? "What Summary calls it" : "")
    #endif
  }

  /// Why saving was refused.
  @ViewBuilder private var saveError: some View {
    if let message = store.saveError {
      Section {
        Text(message)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  #if os(macOS)
    /// The card's symbol, opening a grid of the curated ones.
    private var symbolButton: some View {
      Button {
        store.isSymbolPickerPresented = true
      } label: {
        Image(systemName: store.symbol)
          .foregroundStyle(color)
          .frame(width: 24, height: 18)
      }
      .accessibilityLabel("Symbol")
      .accessibilityValue(store.symbol)
      .popover(isPresented: $store.isSymbolPickerPresented, arrowEdge: .trailing) {
        CardSymbolGrid(selection: store.symbol, color: color) { store.send(.symbolChosen($0)) }
      }
    }
  #endif

  /// A field's errors, under its section, or nothing.
  @ViewBuilder private func errors(_ messages: [String]) -> some View {
    if !messages.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(messages, id: \.self) { message in
          Text(message)
        }
      }
      .foregroundStyle(.red)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// A place in the editor's form a catalog's state scrolls to: the first row of a section.
enum CardEditorAnchor: Hashable {
  case series(String)
  case addSeries
  case chart
  case formula(String)
  case addFormula
  case delete
}

/// Types by category in the sidebar's order, each category's by name.
struct CardTypeGroup: Identifiable {
  let name: String
  let types: [HealthDataType]

  var id: String { name }

  static func grouping(_ types: [HealthDataType]) -> [CardTypeGroup] {
    let byName: ([HealthDataType]) -> [HealthDataType] = {
      $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var groups = HealthCategory.allCases.compactMap { category -> CardTypeGroup? in
      let types = types.filter { $0.category == category }
      return types.isEmpty ? nil : CardTypeGroup(name: category.name, types: byName(types))
    }
    let other = types.filter { $0.category == nil }
    if !other.isEmpty { groups.append(CardTypeGroup(name: "Other", types: byName(other))) }
    return groups
  }
}

/// The curated symbols (`HealthCards.cardSymbols`) in a grid, the card's in its color, the chosen
/// one on a swatch of it: the Mac's popover, 8 across, and the iPhone's page, 7 across at a
/// finger's size.
public struct CardSymbolGrid: View {
  let selection: String
  let color: Color
  let choose: (String) -> Void

  public init(selection: String, color: Color, choose: @escaping (String) -> Void) {
    self.selection = selection
    self.color = color
    self.choose = choose
  }

  #if os(iOS)
    private static let columns = 7
    private static let cellSize: CGFloat = 44
    private static let symbolSize: CGFloat = 20
    private static let spacing: CGFloat = 6
  #else
    private static let columns = 8
    private static let cellSize: CGFloat = 32
    private static let symbolSize: CGFloat = 16
    private static let spacing: CGFloat = 4
  #endif

  public var body: some View {
    let symbols = HealthCards.cardSymbols
    Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
      ForEach(Array(stride(from: 0, to: symbols.count, by: Self.columns)), id: \.self) { start in
        GridRow {
          ForEach(symbols[start..<min(start + Self.columns, symbols.count)], id: \.self) {
            symbol in
            cell(symbol)
          }
        }
      }
    }
    .padding(10)
  }

  private func cell(_ symbol: String) -> some View {
    let isSelected = symbol == selection
    return Button {
      choose(symbol)
    } label: {
      Image(systemName: symbol)
        .font(.system(size: Self.symbolSize))
        .foregroundStyle(isSelected ? Color.white : color)
        .frame(width: Self.cellSize, height: Self.cellSize)
        .background(isSelected ? color : Color.clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(symbol)
    .accessibilityLabel(symbol)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

#if os(iOS)
  /// The symbols as a page the editor's sheet pushes, which a choice closes.
  public struct CardSymbolPage: View {
    let selection: String
    let color: Color
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(selection: String, color: Color, choose: @escaping (String) -> Void) {
      self.selection = selection
      self.color = color
      self.choose = choose
    }

    public var body: some View {
      ScrollView {
        CardSymbolGrid(selection: selection, color: color) { symbol in
          choose(symbol)
          dismiss()
        }
        .frame(maxWidth: .infinity)
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationTitle("Symbol")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
#endif

/// The palette (`CardColor`), a swatch each, the chosen one ringed: a row on the Mac, and a grid
/// of finger-sized ones filling the iPhone's row.
public struct CardColorSwatches: View {
  let selection: CardColor
  let choose: (CardColor) -> Void

  public init(selection: CardColor, choose: @escaping (CardColor) -> Void) {
    self.selection = selection
    self.choose = choose
  }

  public var body: some View {
    #if os(iOS)
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8)
      {
        swatches(size: 28)
      }
      .padding(.vertical, 4)
    #else
      HStack(spacing: 4) {
        swatches(size: 16)
      }
    #endif
  }

  private func swatches(size: CGFloat) -> some View {
    ForEach(CardColor.allCases, id: \.self) { color in
      let isSelected = color == selection
      Button {
        choose(color)
      } label: {
        Circle()
          .fill(Color(paletteName: color.rawValue))
          .frame(width: size, height: size)
          .padding(size / 16 * 3)
          .overlay {
            if isSelected {
              Circle().strokeBorder(Color.primary.opacity(0.7), lineWidth: 2)
            }
          }
          .contentShape(.circle)
      }
      .buttonStyle(.plain)
      .help(color.rawValue.capitalized)
      .accessibilityLabel(color.rawValue.capitalized)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
  }
}

extension CardSpec {
  /// The spec with a fixed name, symbol and color, and no labels: what a card's data depends on.
  public var withoutAppearance: CardSpec {
    var spec = self
    spec.display.name = ""
    spec.display.symbol = ""
    spec.display.color = .gray
    for index in spec.series.indices { spec.series[index].label = nil }
    for index in spec.formulas.indices { spec.formulas[index].label = nil }
    return spec
  }

  /// Whether the two specs are the same but for their name, symbol and color: whether an edit
  /// changed only those. A unit is part of what a card shows.
  public func hasQuery(of other: CardSpec) -> Bool {
    var mine = self
    mine.display.name = other.display.name
    mine.display.symbol = other.display.symbol
    mine.display.color = other.display.color
    return mine == other
  }
}

/// The preview, however it got its state: the card as its page draws it, or, for a new card
/// before its type, the chart's space saying what's missing.
public struct CardPreviewContent: View {
  let spec: CardSpec?
  let state: CardChart.State
  /// The period shown before its data loads.
  var offset = 0

  public init(spec: CardSpec?, state: CardChart.State, offset: Int = 0) {
    self.spec = spec
    self.state = state
    self.offset = offset
  }

  public static let chartHeight: CGFloat = 200

  public var body: some View {
    if let spec {
      CardChart(
        spec: spec, range: spec.range, offset: offset, state: state,
        chartHeight: Self.chartHeight)
    } else {
      // The space a card of one series takes, so nothing moves once a type is picked.
      CardChart(
        spec: HealthCards.welcomeSeed[0].spec, range: .week, offset: 0, state: .loading,
        chartHeight: Self.chartHeight
      )
      .hidden()
      .overlay {
        ContentUnavailableView(
          "Choose a Type", systemImage: "chart.xyaxis.line",
          description: Text("Pick what this card charts, under Data."))
      }
    }
  }
}
