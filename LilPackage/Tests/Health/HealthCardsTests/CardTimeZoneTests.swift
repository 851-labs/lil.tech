import Foundation
import Testing

@testable import HealthCards

/// The names the tools' `timeZone` and records' `HKTimeZone` take (851-4184, 851-4185): the
/// server's tests run the same cases (`Services/api/test/health/tools/conformance/time-zones.json`)
/// against `namedTimeZone`.
struct CardTimeZoneTests {
  struct Cases: Decodable {
    var instants: [Date]
    var cases: [Case]

    struct Case: Decodable, CustomTestStringConvertible {
      var name: String
      var zone: Bool
      var offsets: [Int]?
      var properName: String?

      var testDescription: String { "\"\(name)\"" }
    }
  }

  static let cases: Cases = {
    let url = CardFilesTests.root.appending(
      path: "Services/api/test/health/tools/conformance/time-zones.json")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(Cases.self, from: Data(contentsOf: url))
    } catch {
      fatalError("Couldn't read \(url.path): \(error)")
    }
  }()

  @Test(arguments: cases.cases)
  func name(_ item: Cases.Case) throws {
    let zone = CardTimeZone.named(item.name)
    #expect((zone != nil) == item.zone)
    if let zone, let offsets = item.offsets {
      #expect(Self.cases.instants.map { zone.secondsFromGMT(for: $0) } == offsets)
    }
    #expect(CardTimeZone.properName(of: item.name) == item.properName)
  }

  /// Foundation knows every listed name, so the Mac takes each. Not the other way round: Apple
  /// updates a Mac's tzdata on its own, so whether Foundation knows a name the list lacks depends
  /// on the Mac. The server's tests check that against Node's pinned ICU.
  @Test
  func foundationKnowsEveryName() {
    let unknown = CardTimeZone.names.filter { TimeZone(identifier: $0) == nil }
    #expect(unknown.isEmpty, "\(unknown.sorted())")
  }

  /// No two names differ only by case, so a name in the wrong case suggests one.
  @Test
  func namesDifferByMoreThanCase() {
    #expect(Set(CardTimeZone.names.map { $0.lowercased() }).count == CardTimeZone.names.count)
  }
}
