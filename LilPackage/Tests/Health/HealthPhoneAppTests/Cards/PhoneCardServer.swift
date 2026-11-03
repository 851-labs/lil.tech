import ConcurrencyExtras
import CryptoKit
import Foundation
import HTTPTypes
import HealthCardStore
import HealthCards
import LilAPI
import LilGzip
import LilSync
import OpenAPIRuntime
import Testing

/// An account's store in memory, as the iPhone syncs with it (`docs/sync/protocol.md`): a change
/// log of cards among the Health records the iPhone uploads, which pushes append to in order of
/// arrival; the change feed with its `entities` filter (851-3221); and the latest snapshot, with
/// parts of every entity, so tests can tell what the iPhone asked for and downloaded.
final class PhoneCardServer: Sendable {
  struct State {
    var changes: [Components.Schemas.Change] = []
    /// Each push's mutations, as sent.
    var pushes: [[Mutation]] = []
    /// Pushes fail as unavailable, as when the store is down.
    var failingPushes = false
    /// The change feed's requests: `after` and `entities`.
    var pulls: [(after: Int, entities: String?)] = []
    /// Ignore `entities`, like a server from before the filter.
    var ignoresEntities = false
    /// The latest snapshot, and each part's bytes by URL.
    var snapshot: Components.Schemas.SnapshotManifest?
    var partBytes: [String: Data] = [:]
    /// The parts downloaded, by URL.
    var downloads: [String] = []
    /// Runs after a push is applied, e.g. to write another device's change right after it.
    var afterPush: (@Sendable (inout State) -> Void)?

    var head: Int { changes.last?.seq ?? 0 }

    /// Appends a change, as another device's write, or the iPhone's upload of a Health record.
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

  /// Appends another device's (or an agent's) write of a card, as a whole row.
  func write(_ card: Card) {
    state.withValue { $0.append(Card.entity, card.id, op: "upsert", row: Self.row(card)) }
  }

  /// The seed's six cards, as the store writes them when it starts (851-3203).
  func seed() {
    for card in seedCards { write(card) }
  }

  /// Health records the iPhone uploaded, which it must never pull back.
  func uploadSamples(_ count: Int) {
    state.withValue { state in
      for _ in 0..<count {
        state.append(
          "health_sample", UUID().uuidString.lowercased(), op: "upsert",
          row: try? OpenAPIObjectContainer(unvalidatedValue: Self.sample))
      }
    }
  }

  static let sample: [String: (any Sendable)?] = [
    "type": "HKQuantityTypeIdentifierStepCount", "startDate": 1_760_400_000_000,
    "endDate": 1_760_400_600_000, "value": 412, "unit": "count", "sourceName": "Test iPhone",
    "sourceBundleId": "com.example",
  ]

  /// A card's whole row, as apps write it.
  static func row(_ card: Card) -> OpenAPIObjectContainer? {
    try? card.upsert().row
  }

  /// Publishes a snapshot of the log so far: a part of Health samples, and one of `cards`.
  func publishSnapshot(cards: [Card], samples: Int) throws {
    func part(_ name: String, _ records: [[String: (any Sendable)?]]) throws
      -> Components.Schemas.SnapshotPart
    {
      let lines = try records.map { record in
        String(
          decoding: try JSONEncoder().encode(OpenAPIObjectContainer(unvalidatedValue: record)),
          as: UTF8.self)
      }
      let gzip = try Gzip.compress(Data(lines.joined(separator: "\n").utf8))
      let url = "https://parts.test/\(name)"
      state.withValue { $0.partBytes[url] = gzip }
      let sha = SHA256.hash(data: gzip).map { String(format: "%02x", $0) }.joined()
      return .init(url: url, records: records.count, bytes: gzip.count, sha256: sha)
    }
    let sampleRecords = (0..<samples).map { index in
      var record = Self.sample
      record["id"] = "6f1c2a40-0000-4000-8000-\(String(format: "%012d", index))"
      return record
    }
    let cardRecords = cards.map { card in
      var record = Self.row(card)?.value ?? [:]
      record["id"] = card.id
      return record
    }
    let samplePart = try part("health_sample", sampleRecords)
    let cardPart = try part("health_card", cardRecords)
    state.withValue {
      $0.snapshot = .init(
        id: "snp_1", seq: $0.head, epoch: 1, createdAt: 0,
        entities: [
          .init(entity: "health_sample", parts: [samplePart]),
          .init(entity: "health_card", parts: [cardPart]),
        ])
    }
  }

  var downloader: SnapshotDownloader {
    SnapshotDownloader { [state] url in
      try state.withValue { state in
        state.downloads.append(url.absoluteString)
        guard let data = state.partBytes[url.absoluteString] else {
          throw SnapshotDownloader.Failed(statusCode: 404)
        }
        return data
      }
    }
  }

  var client: Client {
    .mock { [state] request, body in
      let url = try #require(URLComponents(string: "https://api.test\(request.path ?? "")"))
      let json = { (status: HTTPResponse.Status, value: any Encodable) throws in
        (
          HTTPResponse(status: status, headerFields: [.contentType: "application/json"]),
          HTTPBody(try JSONEncoder().encode(value)) as HTTPBody?
        )
      }
      switch (request.method, url.path) {
      case (.get, "/v1/sync/snapshot"):
        return try json(
          .ok, Components.Schemas.LatestSnapshot(epoch: 1, snapshot: state.value.snapshot))

      case (.get, "/v1/sync/changes"):
        let query = Dictionary(
          (url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let after = Int(query["after"] ?? "0") ?? 0
        let limit = Int(query["limit"] ?? "1000") ?? 1000
        let entities = query["entities"]
        let page = state.withValue { state in
          state.pulls.append((after, entities))
          let names =
            state.ignoresEntities
            ? nil : entities.map { Set($0.split(separator: ",").map(String.init)) }
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
        return try json(.ok, page)

      case (.post, "/v1/sync/mutations"):
        let data = try await Data(collecting: try #require(body), upTo: 1 << 20)
        let push = try JSONDecoder().decode(Push.self, from: data)
        if state.value.failingPushes {
          return try json(
            .serviceUnavailable,
            Components.Schemas.UserStoreUnavailable(
              _tag: .userStoreUnavailable, message: "Unavailable"))
        }
        let seq = state.withValue { state in
          state.pushes.append(push.mutations)
          for mutation in push.mutations {
            state.append(mutation.entity, mutation.id, op: mutation.op, row: mutation.row)
          }
          let seq = state.head
          state.afterPush?(&state)
          return seq
        }
        return try json(.ok, Components.Schemas.PushedMutations(seq: seq))

      default:
        Issue.record("Unexpected request: \(request.method) \(url.path)")
        return (HTTPResponse(status: .notFound), nil)
      }
    }
  }
}

/// The seed's six cards, as pulled.
let seedCards = HealthCards.welcomeSeed.map {
  Card(
    id: $0.id, spec: $0.spec, position: $0.position, createdAt: 1_760_400_000_000,
    updatedAt: 1_760_400_000_000, seed: $0.seed)
}

/// A generator whose numbers are always the same, for card IDs.
struct FixedGenerator: RandomNumberGenerator {
  var value: UInt64 = 0
  mutating func next() -> UInt64 {
    value &+= 0x9e37_79b9_7f4a_7c15
    return value
  }
}
