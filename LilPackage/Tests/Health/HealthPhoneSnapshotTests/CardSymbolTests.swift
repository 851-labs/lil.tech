#if os(iOS)
  import HealthCards
  import Testing
  import UIKit

  // Not a catalog: the iPhone's half of the cards' symbol check (851-3194), here because this is
  // the one test bundle that runs on iOS. The Mac's is `symbolsExistOnTheMac` in HealthCardsTests.
  // It runs with every iPhone catalog (`scripts/snapshot --iphone`, and after each merge). Run on
  // its own, `scripts/snapshot --iphone 'cardSymbolsExist()'` reports that no snapshot test ran,
  // since it takes none: its result is in `LilPackage/.build/snapshots-iphone/test.log`.
  extension PhoneSnapshotTests {
    /// Every curated card symbol draws on the iPhone, so an agent can't pick one that draws
    /// nothing.
    @Test
    func cardSymbolsExist() {
      for symbol in HealthCards.cardSymbols {
        #expect(UIImage(systemName: symbol) != nil, "\(symbol)")
      }
    }
  }
#endif
