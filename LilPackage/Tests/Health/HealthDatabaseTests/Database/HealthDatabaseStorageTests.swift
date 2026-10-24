import CustomDump
import Dependencies
import Foundation
import HealthDatabase
import SQLiteData
import Testing

@Suite
struct HealthDatabaseStorageTests {
  @Test(arguments: [DependencyContext.test, .preview])
  func defaultDatabasesStayInMemoryAndAreIsolated(context: DependencyContext) throws {
    try withDependencies {
      $0.context = context
    } operation: {
      let database = try HealthDatabase.make()
      let otherDatabase = try HealthDatabase.make()
      defer {
        try? database.close()
        try? otherDatabase.close()
      }

      let path = try database.read { db in
        try String.fetchOne(db, sql: "SELECT file FROM pragma_database_list WHERE name = 'main'")
      }
      expectNoDifference(path, "")

      try database.write { db in
        try HealthSample.insert { sample }.execute(db)
      }
      expectNoDifference(try database.read { try HealthSample.fetchCount($0) }, 1)
      expectNoDifference(try otherDatabase.read { try HealthSample.fetchCount($0) }, 0)
      expectNoDifference(
        try database.read { db in
          try Int.fetchOne(db, sql: "SELECT 'é' COLLATE canonical = 'e\u{301}'")
        }, 1)
    }
  }

  @Test(arguments: [DependencyContext.test, .preview, .live])
  func explicitDatabaseFilesPersistAndCanBeRemoved(context: DependencyContext) throws {
    let directory = URL.temporaryDirectory.appending(
      path: "HealthDatabaseStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "Health.sqlite")

    try withDependencies {
      $0.context = context
    } operation: {
      let database = try HealthDatabase.make(at: url)
      try database.write { db in
        try HealthSample.insert { sample }.execute(db)
      }
      try database.close()
      #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

      let reopened = try HealthDatabase.make(at: url)
      expectNoDifference(try reopened.read { try HealthSample.fetchCount($0) }, 1)
      try reopened.close()
    }

    try FileManager.default.removeItem(at: directory)
    #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
  }

  private var sample: HealthSample {
    HealthSample(
      id: "storage-probe", type: "HKQuantityTypeIdentifierStepCount", startDate: 0, endDate: 1_000,
      value: 1, unit: "count", sourceName: "Test", sourceBundleID: "com.example")
  }
}
