#if os(macOS)
  import HealthDatabase
  @testable import HealthMacApp
  import SwiftUI
  import Testing

  // Reorder Cards… (851-3210, `ReorderCardsContent`): Summary's cards in a list, to drag into
  // order, at the sheet's size. Dragging itself only shows in a real window.

  extension MacSnapshotTests {
    @Test(arguments: reorderCardsCatalog.selectedStates)
    func reorderCards(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let reorderCardsCatalog = StateCatalog(
    "Reorder Cards", width: ReorderCardsContent.width, minHeight: ReorderCardsContent.height,
    states: [
      CatalogState("Welcome seed") { reorder(seedCards) },
      // Two cards, the fewest it opens with.
      CatalogState("Two cards") { reorder(Array(seedCards.prefix(2))) },
      // More than fit: the list scrolls, and Done stays at the bottom. A later version's card
      // shows the name, symbol and color this version can read.
      CatalogState("Many cards, one from a later version") {
        reorder(
          Array(seedCards.prefix(2)) + [laterVersionCard] + seedCards.dropFirst(2) + exampleCards)
      },
    ])

  @MainActor
  private func reorder(_ cards: [Card]) -> some View {
    ReorderCardsContent(cards: cards)
      .frame(height: ReorderCardsContent.height)
      .background(.background)
  }
#endif
