public import SQLiteData

// The cards live in `HealthCardStore` (851-3205), which the iPhone shares; the Mac reads them
// through its health database as before.
extension HealthDatabase {
  /// The account's cards, in Summary's order.
  public static func cards(_ db: Database) throws -> [Card] {
    try HealthCardStore.cards(db)
  }

  /// The cards now, then each time they change: this Mac's writes, and other devices' and agents'
  /// as sync brings them.
  public static func cardUpdates(
    in database: any DatabaseReader
  ) -> AsyncThrowingStream<[Card], any Error> {
    HealthCardStore.cardUpdates(in: database)
  }
}
