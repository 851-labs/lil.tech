public import HealthCardStore
public import SwiftUI

// On both apps' card pages (851-3207, 851-3212).

/// A card of a later version's page: its name, symbol and color, as far as this version can read
/// them, and that it can't show the card.
public struct CardUnreadableContent: View {
  let card: Card

  public init(card: Card) {
    self.card = card
  }

  public var body: some View {
    let display = card.storedDisplay
    ContentUnavailableView {
      Label(display.name, systemImage: display.symbol)
        .foregroundStyle(display.color ?? .secondary)
    } description: {
      Text("Update lil health to show this card.")
    }
    .navigationTitle(display.name)
  }
}
