import Foundation
import MessagesDatabase
import SQLiteData
import Tagged
import Testing

struct ChatDatabaseTests {
  @Test
  func liveThrowsWhenFileIsMissing() throws {
    let url = URL.temporaryDirectory.appending(path: "\(UUID()).db")
    let chatDatabase = ChatDatabase.live(url: url)

    let error = try #require(throws: ChatDatabaseUnavailable.self) {
      try chatDatabase.reader()
    }
    #expect(error.url == url)
  }

  @Test
  func liveThrowsWhenFileIsUnreadable() throws {
    let url = try makeChatDatabaseFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: url.path(percentEncoded: false))

    #expect(throws: ChatDatabaseUnavailable.self) {
      try ChatDatabase.live(url: url).reader()
    }
  }

  @Test
  func liveOpensReadOnly() throws {
    let url = try makeChatDatabaseFile()
    defer { try? FileManager.default.removeItem(at: url) }

    let reader = try ChatDatabase.live(url: url).reader()

    let count = try reader.read { db in try Handle.fetchCount(db) }
    #expect(count == 1)
    let writer = try #require(reader as? DatabaseQueue)
    let error = try #require(throws: DatabaseError.self) {
      try writer.write { db in
        try db.execute(sql: "DELETE FROM handle")
      }
    }
    #expect(error.resultCode == .SQLITE_READONLY)
  }

  @Test
  func liveRetriesUntilFileExists() throws {
    let url = URL.temporaryDirectory.appending(path: "\(UUID()).db")
    defer { try? FileManager.default.removeItem(at: url) }
    let chatDatabase = ChatDatabase.live(url: url)

    #expect(throws: ChatDatabaseUnavailable.self) {
      try chatDatabase.reader()
    }

    try makeChatDatabaseFile(at: url)
    let reader = try chatDatabase.reader()
    #expect(try reader.read { db in try Handle.fetchCount(db) } == 1)
  }

  @Test
  func liveReusesTheOpenedReader() throws {
    let url = try makeChatDatabaseFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let chatDatabase = ChatDatabase.live(url: url)

    let first = try #require(try chatDatabase.reader() as? DatabaseQueue)
    let second = try #require(try chatDatabase.reader() as? DatabaseQueue)
    #expect(first === second)
  }

  @discardableResult
  private func makeChatDatabaseFile(
    at url: URL = URL.temporaryDirectory.appending(path: "\(UUID()).db")
  ) throws -> URL {
    let inMemory = try makeInMemoryChatDatabase()
    try inMemory.write { db in
      try db.seed {
        Handle(id: 1, address: "+15550000001", service: "iMessage")
      }
    }
    let file = try DatabaseQueue(path: url.path(percentEncoded: false))
    try inMemory.backup(to: file)
    try file.close()
    return url
  }
}
