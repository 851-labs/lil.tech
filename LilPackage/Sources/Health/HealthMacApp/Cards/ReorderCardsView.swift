import ComposableArchitecture
import HealthCardEditor
import HealthCards
import HealthDatabase
import HealthUI
import SwiftUI

/// Reorder Cards… (851-3210, docs/decisions/cards.md, UI › Mac): the cards in Summary's order, to
/// drag into another. Summary's grouped form can't reorder its rows by dragging (a `Form` isn't a
/// table on the Mac, so `onMove` does nothing there), so the drag happens in a `List`, which
/// can. Each move is `CardsFeature`'s: one write, of the moved card, synced.
struct ReorderCardsView: View {
  let store: StoreOf<CardsFeature>

  var body: some View {
    let cards = Array(store.cards)
    ReorderCardsContent(
      cards: cards,
      move: { source, destination in
        // By the cards the list showed, not their places, in case sync changed them meanwhile.
        store.send(
          .moveCardsBefore(
            ids: source.map { cards[$0].id },
            before: destination < cards.count ? cards[destination].id : nil))
      },
      done: { store.send(.reorderingFinished) })
  }
}

/// What Reorder Cards… shows, however it got the cards.
struct ReorderCardsContent: View {
  let cards: [Card]
  /// Moves the cards at the offsets to before the offset, as `onMove` gives them.
  var move: (IndexSet, Int) -> Void = { _, _ in }
  var done: () -> Void = {}

  /// The sheet's size in the app: the welcome seed's six fit without scrolling.
  nonisolated static var width: CGFloat { 400 }
  nonisolated static var height: CGFloat { 440 }

  var body: some View {
    VStack(spacing: 0) {
      // A sheet has no title bar: its title and what to do, over the list.
      VStack(alignment: .leading, spacing: 4) {
        Text("Reorder Cards")
          .font(.headline)
        Text("Drag cards to change their order on Summary, on all your devices.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding([.horizontal, .top], 20)
      .padding(.bottom, 12)
      List {
        ForEach(cards) { card in
          ReorderCardRow(card: card)
        }
        .onMove(perform: move)
      }
      .listStyle(.inset)
      Divider()
      HStack {
        Spacer()
        Button("Done", action: done)
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
  }
}

/// A card in Reorder Cards…: its symbol and name in its color, a later version's as far as this
/// version can read them, and a handle saying it can be dragged.
struct ReorderCardRow: View {
  let card: Card

  var body: some View {
    let display =
      card.spec.map {
        (
          name: $0.display.name, symbol: $0.display.symbol,
          color: Color(paletteName: $0.display.color.rawValue) as Color?
        )
      } ?? card.storedDisplay
    HStack {
      Label(display.name, systemImage: display.symbol)
        .lineLimit(1)
        .foregroundStyle(display.color ?? .secondary)
      Spacer()
      Image(systemName: "line.3.horizontal")
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 4)
  }
}
