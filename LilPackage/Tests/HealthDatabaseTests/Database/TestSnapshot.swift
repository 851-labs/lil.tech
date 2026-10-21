import CryptoKit
import Foundation
import HTTPTypes
import LilAPI
import LilGzip
import LilSync
import OpenAPIRuntime
import Testing

/// A store's latest snapshot, served from memory: gzip NDJSON parts of each entity's records, as
/// a store writes them (`docs/SYNC.md`). For `LilSyncEngine.bootstrap()` without a stage.
struct TestSnapshot {
  let manifest: Components.Schemas.SnapshotManifest
  let parts: [String: Data]

  /// Each entity's records, as JSON lines, in parts of at most `partRecords`.
  init(seq: Int, entities: [(name: String, lines: [String])], partRecords: Int = 25_000) throws {
    var parts: [String: Data] = [:]
    let manifestEntities = try entities.map { entity in
      var entityParts: [Components.Schemas.SnapshotPart] = []
      for start in stride(from: 0, to: entity.lines.count, by: partRecords) {
        let lines = entity.lines[start..<min(start + partRecords, entity.lines.count)]
        let bytes = try Gzip.compress(Data((lines.joined(separator: "\n") + "\n").utf8))
        let url = "https://parts.test/\(entity.name)/\(start)"
        parts[url] = bytes
        let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        entityParts.append(
          .init(url: url, records: lines.count, bytes: bytes.count, sha256: sha256))
      }
      return Components.Schemas.SnapshotEntity(entity: entity.name, parts: entityParts)
    }
    self.parts = parts
    manifest = .init(id: "snp_test", seq: seq, epoch: 1, createdAt: 0, entities: manifestEntities)
  }

  /// Answers `GET /v1/sync/snapshot` with the snapshot.
  var client: Client {
    let latest = Components.Schemas.LatestSnapshot(epoch: 1, snapshot: manifest)
    return .mock { request, _ in
      #expect(request.path == "/v1/sync/snapshot")
      return (
        HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
        HTTPBody(try JSONEncoder().encode(latest))
      )
    }
  }

  var downloader: SnapshotDownloader {
    SnapshotDownloader { [parts] url in
      guard let data = parts[url.absoluteString] else {
        throw SnapshotDownloader.Failed(statusCode: 404)
      }
      return data
    }
  }
}
