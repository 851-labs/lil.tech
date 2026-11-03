import ComposableArchitecture
import HealthCards
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import SQLiteData
import SwiftUI

// The card editor (851-3208, docs/decisions/cards.md, UI › Mac): a sheet, a grouped form with the
// card's live preview at the top, then its name, symbol and color, what it charts, and Delete
// Card… for one of the account's cards. Cancel and Save are in the toolbar.

/// The card editor's sheet, with `preview` drawing the card for the spec the preview shows: the
/// app's runs it on the local database (`CardEditorPreview`), a catalog's gives its state.
struct CardEditorView<Preview: View>: View {
  @Bindable var store: StoreOf<CardEditorFeature>
  @ViewBuilder let preview: (CardSpec?) -> Preview

  /// The sheet's size in the app.
  static var width: CGFloat { 560 }
  static var height: CGFloat { 700 }

  private var color: Color { Color(paletteName: store.color.rawValue) }

  var body: some View {
    Form {
      Section {
        preview(store.preview)
          .padding(.vertical, 6)
      }
      Section {
        TextField(
          "Name", text: $store.name.sending(\.nameChanged),
          prompt: Text(store.isNew ? "What Summary calls it" : "")
        )
        // Below the preview, the fields keep their place, loaded or not (851-3084).
        .layoutAnchor("Name")
      } footer: {
        errors(store.state.errors(for: .name))
      }
      Section {
        LabeledContent("Symbol") {
          symbolButton
        }
        LabeledContent("Color") {
          CardColorSwatches(selection: store.color) { store.send(.colorChosen($0)) }
        }
      } footer: {
        errors(store.state.errors(for: .symbol) + store.state.errors(for: .color))
      }
      Section {
        if store.isNew {
          typePicker
        } else if let original = store.original {
          // What it charts, which the query builder (851-3209) edits.
          Text(original.about)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } header: {
        Text("Data")
      } footer: {
        errors(store.state.errors(for: .query) + (store.saveError.map { [$0] } ?? []))
      }
      if !store.isNew {
        Section {
          Button("Delete Card…", role: .destructive) {
            store.send(.deleteButtonTapped)
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(store.isNew ? "New Card" : "Edit Card")
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

  /// A new card's one series' type: the chartable types by category, as the sidebar lists them.
  private var typePicker: some View {
    Picker(
      "Type",
      selection: Binding(
        get: { store.typeID },
        set: { id in if let id { store.send(.typeChosen(id)) } })
    ) {
      if store.typeID == nil {
        Text("Choose…").tag(String?.none)
      }
      ForEach(CardTypeGroup.all, id: \.name) { group in
        Section(group.name) {
          ForEach(group.types) { type in
            Text(type.name).tag(String?.some(type.id))
          }
        }
      }
    }
  }

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

/// The types a card's series can chart, by category in the sidebar's order, each category's by
/// name.
struct CardTypeGroup {
  let name: String
  let types: [HealthDataType]

  static let all: [CardTypeGroup] = {
    let byName: ([HealthDataType]) -> [HealthDataType] = {
      $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var groups = HealthCategory.allCases.compactMap { category -> CardTypeGroup? in
      let types = HealthCards.chartableTypes.filter { $0.category == category }
      return types.isEmpty ? nil : CardTypeGroup(name: category.name, types: byName(types))
    }
    let other = HealthCards.chartableTypes.filter { $0.category == nil }
    if !other.isEmpty { groups.append(CardTypeGroup(name: "Other", types: byName(other))) }
    return groups
  }()
}

/// The curated symbols (`HealthCards.cardSymbols`) in a grid, the card's in its color, the chosen
/// one on a swatch of it.
struct CardSymbolGrid: View {
  let selection: String
  let color: Color
  let choose: (String) -> Void

  private static let columns = 8

  var body: some View {
    let symbols = HealthCards.cardSymbols
    Grid(horizontalSpacing: 4, verticalSpacing: 4) {
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
        .font(.system(size: 16))
        .foregroundStyle(isSelected ? Color.white : color)
        .frame(width: 32, height: 32)
        .background(isSelected ? color : Color.clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(symbol)
    .accessibilityLabel(symbol)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// The palette (`CardColor`), a swatch each, the chosen one ringed.
struct CardColorSwatches: View {
  let selection: CardColor
  let choose: (CardColor) -> Void

  var body: some View {
    HStack(spacing: 4) {
      ForEach(CardColor.allCases, id: \.self) { color in
        let isSelected = color == selection
        Button {
          choose(color)
        } label: {
          Circle()
            .fill(Color(paletteName: color.rawValue))
            .frame(width: 16, height: 16)
            .padding(3)
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
}

/// The editor's live preview, from the local database: the card at its range, on the latest
/// period with data, as its page opens (851-3188). The last spec's stays, with the delayed
/// spinner, while the next loads (851-3084, 851-3086).
struct CardEditorPreview: View {
  let spec: CardSpec?
  @Fetch private var chart: CardPeriod? = nil

  /// What the data depends on: the spec without its name, symbol and color, so choosing those
  /// runs nothing again.
  private var query: CardSpec? { spec?.withoutAppearance }

  var body: some View {
    CardPreviewContent(spec: spec, state: state, offset: chart?.offset ?? 0)
      .task(id: query) {
        guard let query else { return }
        _ = try? await $chart.load(
          CardPreviewRequest(spec: query), scheduler: MainQueueScheduler())
      }
  }

  private var state: CardChart.State {
    if let error = $chart.loadError { return .failed(error.localizedDescription) }
    guard let chart, let spec else { return .loading }
    // The data drawn as the spec looks now.
    let period = CardPeriod(
      range: chart.range, offset: chart.offset,
      spec: chart.spec == query ? spec : chart.spec, data: chart.data)
    return .loaded(period, isUpdating: $chart.isLoading || chart.spec != query)
  }
}

extension CardSpec {
  /// The spec with a fixed name, symbol and color: what a card's data depends on.
  var withoutAppearance: CardSpec {
    var spec = self
    spec.display.name = ""
    spec.display.symbol = ""
    spec.display.color = .gray
    return spec
  }
}

/// The preview, however it got its state: the card as its page draws it, or, for a new card
/// before its type, the chart's space saying what's missing.
struct CardPreviewContent: View {
  let spec: CardSpec?
  let state: CardChart.State
  /// The period shown before its data loads.
  var offset = 0

  static let chartHeight: CGFloat = 200

  var body: some View {
    if let spec {
      CardChart(
        spec: spec, range: ChartRange(spec.range), offset: offset, state: state,
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

/// A card at its range, on the latest period with its lead's data, as its page opens.
struct CardPreviewRequest: FetchKeyRequest {
  let spec: CardSpec

  func fetch(_ db: Database) throws -> CardPeriod? {
    // The dependencies where the fetch started (SQLiteData passes them on), so snapshot
    // catalogs fix them.
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    let range = ChartRange(spec.range)
    let latest = try spec.leadType.flatMap {
      try HealthDatabase.latestPeriodDate(of: $0, by: now, calendar: calendar, db)
    }
    let offset = range.openingOffset(latest: latest, now: now, calendar: calendar)
    return try CardDataRequest(spec: spec, range: range, offset: offset).fetch(db)
  }
}
