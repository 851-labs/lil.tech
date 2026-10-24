import ConcurrencyExtras
import Foundation
import HTTPTypes
import HealthCards
import LilAPI
import OpenAPIRuntime
import Testing

/// A store's sync endpoints in memory, for cards (`docs/sync/protocol.md`): its change log, which
/// pushes append to in order of arrival, the change feed with its `entities` filter, and no
/// snapshot, so a catch-up reads the log from the start.
final class CardSyncServer: Sendable {
  struct State {
    var changes: [Components.Schemas.Change] = []
    /// Each push's mutations, as sent.
    var pushes: [[Mutation]] = []
    /// The change feed's requests: `after` and `entities`.
    var pulls: [(after: Int, entities: String?)] = []
    var snapshotRequests = 0
    /// Runs after a push is applied, e.g. to write another device's change right after it.
    var afterPush: (@Sendable (inout State) -> Void)?

    var head: Int { changes.last?.seq ?? 0 }

    /// Appends a change, as another device's write.
    mutating func append(
      _ entity: String, _ id: String, op: String, row: OpenAPIObjectContainer? = nil
    ) {
      var row = row
      if var value = row?.value {
        value["id"] = id
        row = try? OpenAPIObjectContainer(unvalidatedValue: value)
      }
      changes.append(
        Components.Schemas.Change(
          seq: head + 1, entity: entity, id: id, op: op, row: row, at: 1_760_400_000_000))
    }
  }

  struct Mutation: Decodable, Sendable {
    let entity: String
    let op: String
    let id: String
    let row: OpenAPIObjectContainer?
  }

  private struct Push: Decodable {
    let mutations: [Mutation]
  }

  let state = LockIsolated(State())

  /// Appends another device's write of a card, as a whole row.
  func write(_ card: (id: String, spec: CardSpec, position: String, updatedAt: Int, seed: String?))
  {
    state.withValue {
      $0.append(
        "health_card", card.id, op: "upsert",
        row: try? Self.row(
          spec: card.spec, position: card.position, createdAt: 1_760_400_000_000,
          updatedAt: card.updatedAt, seed: card.seed))
    }
  }

  /// The seed's six cards, as the store writes them when it starts (851-3203).
  func seed() {
    for card in HealthCards.welcomeSeed {
      write((card.id, card.spec, card.position, 1_760_400_000_000, card.seed))
    }
  }

  static func row(
    spec: CardSpec, position: String, createdAt: Int, updatedAt: Int, seed: String?
  ) throws -> OpenAPIObjectContainer {
    let spec = try JSONDecoder().decode(OpenAPIValueContainer.self, from: Data(spec.jsonText.utf8))
    return try OpenAPIObjectContainer(unvalidatedValue: [
      "spec": spec.value, "position": position, "createdAt": createdAt, "updatedAt": updatedAt,
      "seed": seed,
    ])
  }

  var client: Client {
    .mock { [state] request, body in
      let url = try #require(URLComponents(string: "https://api.test\(request.path ?? "")"))
      let json = { (value: any Encodable) throws -> (HTTPResponse, HTTPBody?) in
        (
          HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
          HTTPBody(try JSONEncoder().encode(value))
        )
      }
      switch (request.method, url.path) {
      case (.get, "/v1/sync/snapshot"):
        state.withValue { $0.snapshotRequests += 1 }
        return try json(Components.Schemas.LatestSnapshot(epoch: 1, snapshot: nil))

      case (.get, "/v1/sync/changes"):
        let query = Dictionary(
          (url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let after = Int(query["after"] ?? "0") ?? 0
        let limit = Int(query["limit"] ?? "1000") ?? 1000
        let entities = query["entities"]
        let names = entities.map { Set($0.split(separator: ",").map(String.init)) }
        let page = state.withValue { state in
          state.pulls.append((after, entities))
          let matching = state.changes.filter {
            $0.seq > after && (names?.contains($0.entity) ?? true)
          }
          let changes = Array(matching.prefix(limit))
          let full = changes.count == limit
          // A filtered page that isn't full moves past what it skipped, up to the head.
          let next =
            full || names == nil ? (changes.last?.seq ?? after) : max(state.head, after)
          return Components.Schemas.ChangesPage(
            epoch: 1, changes: changes, next: next, head: state.head, hasMore: next < state.head)
        }
        return try json(page)

      case (.post, "/v1/sync/mutations"):
        let data = try await Data(collecting: try #require(body), upTo: 1 << 20)
        let push = try JSONDecoder().decode(Push.self, from: data)
        let seq = state.withValue { state in
          state.pushes.append(push.mutations)
          for mutation in push.mutations {
            state.append(mutation.entity, mutation.id, op: mutation.op, row: mutation.row)
          }
          let seq = state.head
          state.afterPush?(&state)
          return seq
        }
        return (
          HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
          HTTPBody(#"{"seq": \#(seq)}"#)
        )

      default:
        Issue.record("Unexpected request: \(request.method) \(url.path)")
        return (HTTPResponse(status: .notFound), nil)
      }
    }
  }
}
