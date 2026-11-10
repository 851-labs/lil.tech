import ComposableArchitecture
public import HealthCardEditor
import HealthCards
import HealthDatabase
import SQLiteData

// The Mac's side of the shared `CardsFeature` (851-3993): the editor's filters' choices from its
// database, and the local MCP server's card writes (851-4014) as agent requests.

extension CardsFeature {
  /// The Mac's cards: loaded once they're read, since Summary and a card's page check that sync
  /// holds them themselves (`HoldsCardsRequest`), with the filters' choices from the database.
  public static var mac: Self {
    Self(filterChoices: .healthDatabase, waitsForSync: false)
  }
}

extension CardFilterChoicesClient {
  /// The apps and device models of a type's samples in this Mac's database (`defaultDatabase`, where
  /// the editor asks), as Data Sources reads them.
  static var healthDatabase: Self {
    Self { type in
      @Dependency(\.defaultDatabase) var database
      let sources = try await database.read { try HealthDatabase.sampleSources(of: type, $0) }
      var seen = Set<String>()
      return CardFilterChoices(
        apps: sources.apps.map { CardFilterChoices.App(id: $0.id, name: $0.name) },
        deviceModels: sources.devices.compactMap(\.device.model).filter {
          seen.insert($0).inserted
        })
    }
  }
}

extension HealthAppActionRequest: AgentCardRequest {
  public var cardChange: AgentCardChange? {
    switch action {
    case .createCard(let spec): .create(spec)
    case .updateCard(let id, let spec): .update(id: id, spec: spec)
    case .deleteCard(let id): .delete(id: id)
    case .reorderCards(let ids): .reorder(ids: ids)
    case .open, .sync, .export, .downloadBlob: nil
    }
  }

  public func answer(_ result: Result<AgentCardAnswer, AgentCardRefusal>) {
    finish(
      result
        .map { answer -> HealthAppActionResult in
          switch answer {
          case .done: .done
          case .card(let id): .card(id: id)
          }
        }
        .mapError { refusal -> any Error in HealthAppActionError.cardNotSaved(refusal.message) })
  }
}
