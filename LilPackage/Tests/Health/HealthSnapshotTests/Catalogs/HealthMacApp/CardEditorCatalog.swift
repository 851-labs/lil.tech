#if os(macOS)
  import ComposableArchitecture
  import Foundation
  import HealthCards
  import HealthDatabase
  @testable import HealthMacApp
  import SQLiteData
  import SwiftUI
  import Testing

  // The card editor (`CardEditorView`, 851-3208): a new card before and after its type is picked,
  // a seed card and an example card edited, inline validation errors, a refused save, the symbol
  // grid and another symbol and color chosen. The preview is the card from the catalog database at
  // `previewNow`, by the app's request. Synthetic data only.

  extension MacSnapshotTests {
    @Test(arguments: cardEditorCatalog.selectedStates)
    func cardEditor(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let cardEditorCatalog = StateCatalog(
    "Card Editor", width: 560, minHeight: 640,
    states: [
      // New Card…: nothing to preview until a type is picked.
      CatalogState("New card") { editor(CardEditorFeature.State()) },
      // The type picked: its name, its category's symbol and color, and its defaults.
      CatalogState("New card, heart rate") { editor(newHeartRate) },
      CatalogState("New card, heart rate, loading") { editor(newHeartRate, preview: .loading) },
      // Edit…: Delete Card… at the bottom, and what it charts under Data.
      CatalogState("Editing steps") { editor(editing(seedCards[0])) },
      CatalogState("Editing steps, loading") {
        editor(editing(seedCards[0]), preview: .loading)
      },
      // Two lines: the preview has the legend.
      CatalogState("Editing morning weight") {
        editor(editing(exampleCards[4]), in: exampleCardsDatabase)
      },
      // Another symbol and color, from the grid and the swatches.
      CatalogState("Another symbol and color") {
        var state = editing(seedCards[0])
        state.symbol = "figure.run"
        state.color = .teal
        state.validate()
        state.preview = state.spec
        return editor(state)
      },
      // The name cleared: its error under it, Save off, and the preview keeps the last valid
      // spec.
      CatalogState("No name") {
        var state = editing(seedCards[0])
        state.name = ""
        state.validate()
        return editor(state)
      },
      CatalogState("Name too long") {
        var state = editing(seedCards[0])
        state.name = "Steps on weekdays, walking to work and back home"
        state.validate()
        return editor(state)
      },
      // Another device brought the account to 100 cards while the editor was open.
      CatalogState("Too many cards") {
        var state = newHeartRate
        state.saveError = "You have 100 cards, the most lil health keeps. Delete one first."
        return editor(state)
      },
      // The popover's grid, the chosen symbol on a swatch of the card's color.
      CatalogState("Symbol picker", width: 320, minHeight: 0) {
        CardSymbolGrid(selection: "heart.fill", color: .red) { _ in }
      },
    ],
    // The fields below the preview stay put while it loads, and once a new card's type is picked
    // (851-3084).
    sameLayout: [
      ["New card", "New card, heart rate", "New card, heart rate, loading"],
      ["Editing steps", "Editing steps, loading"],
    ])

  /// A new card with heart rate picked.
  @MainActor private var newHeartRate: CardEditorFeature.State {
    CardEditorFeature.State(typeID: "HKQuantityTypeIdentifierHeartRate")
  }

  private func editing(_ card: Card) -> CardEditorFeature.State {
    CardEditorFeature.State(editing: card)!
  }

  /// The editor with its preview's state: by default, the preview's spec from `database`, by the
  /// app's request.
  @MainActor
  private func editor(
    _ state: CardEditorFeature.State, preview: CardChart.State? = nil,
    in database: any DatabaseReader = catalogDatabase
  ) -> some View {
    CardEditorView(store: Store(initialState: state) { EmptyReducer() }) { spec in
      CardPreviewContent(
        spec: spec,
        state: preview
          ?? spec.map { spec in
            .loaded(try! database.read { try CardPreviewRequest(spec: spec).fetch($0)! })
          } ?? .loading)
    }
  }
#endif
