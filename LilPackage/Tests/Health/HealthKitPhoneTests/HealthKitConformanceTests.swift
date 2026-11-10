import Foundation
import HealthCards
import HealthConformance
import HealthKit
import HealthKitAccess
import Testing

/// The iPhone's side of the cards' conformance cases (851-3201, docs/decisions/cards.md ›
/// Conformance and tolerance): the cards' dataset written into the simulator's HealthKit, each
/// source's samples and workouts by an app of its own (`ConformanceSourceApps`), then each case's
/// spec run by the HealthKit engine (`HealthKitCardEngine`), whose card data must match what the
/// Mac and the server give, within the same 1e-9. Cases marked `"iphone": {"skip": …}` are those
/// HealthKit can't match, and must still differ: one that matches has lost its reason. So must
/// those `pending` on the iPhone (851-4155), until the ticket they name makes them pass.
///
/// Run it with `scripts/test-iphone-healthkit`, which has the source apps write the dataset after
/// the other suites, whose tests need HealthKit to hold only their own samples, and then runs this
/// one on its own.
@Suite
struct HealthKitConformanceTests {
  /// The dataset in HealthKit, checked once: every source's samples and workouts, from its app,
  /// and none of the host's, which the other suites' last test left, with the zones they were
  /// recorded in (`HKMetadataKeyTimeZone`, 851-4176).
  static let store = Task {
    let health = try await SyntheticHealthKit.empty(allowingOtherSources: true)
    let dataset = try ConformanceSamples.cards()
    var written: [String: Int] = [:]
    var zoned: [String: Int] = [:]
    for type in TestHealthTypes.all {
      let samples = try await HKSampleQueryDescriptor(
        predicates: [.sample(type: type)], sortDescriptors: []
      )
      .result(for: health.store)
      for sample in samples {
        written[sample.sourceRevision.source.bundleIdentifier, default: 0] += 1
        if sample.metadata?[HKMetadataKeyTimeZone] != nil {
          zoned[sample.sourceRevision.source.bundleIdentifier, default: 0] += 1
        }
      }
    }
    var expected: [String: Int] = [:]
    var expectedZoned: [String: Int] = [:]
    for (source, app) in ConformanceSourceApps.apps(for: dataset.sources) {
      let part = dataset.of(source: source).only(types: TestHealthTypes.identifiers)
      expected[app] = part.samples.count + part.workouts.count
      expectedZoned[app] =
        part.samples.count { $0.timeZone != nil } + part.workouts.count { $0.timeZone != nil }
    }
    guard written == expected.filter({ $0.value > 0 }),
      zoned == expectedZoned.filter({ $0.value > 0 })
    else {
      throw NotWritten(
        written: written, expected: expected, zoned: zoned, expectedZoned: expectedZoned)
    }
    return (health.store, ConformanceSourceApps.apps(for: dataset.sources))
  }

  @Test(
    arguments: try CardConformanceCase.cases().filter {
      $0.iphone == nil && $0.pending?.iphone == nil
    })
  func conformanceCase(_ testCase: CardConformanceCase) async throws {
    let output = try await Self.run(testCase)
    #expect(output.matches(testCase.expected), "\(output)\nexpected:\n\(testCase.expected)")
  }

  @Test(arguments: try CardConformanceCase.cases().filter { $0.iphone != nil })
  func skippedCaseDiffers(_ testCase: CardConformanceCase) async throws {
    let output = try await Self.run(testCase)
    #expect(
      !output.matches(testCase.expected),
      "HealthKit matches it: remove its skip (\(testCase.iphone?.skip ?? ""))")
  }

  @Test(
    arguments: try CardConformanceCase.cases().filter {
      $0.iphone == nil && $0.pending?.iphone != nil
    })
  func pendingCaseDiffers(_ testCase: CardConformanceCase) async throws {
    let output = try await Self.run(testCase)
    #expect(
      !output.matches(testCase.expected),
      "HealthKit matches it: remove its pending mark (\(testCase.pending?.iphone ?? ""))")
  }

  /// The case's card data from HealthKit, as the tools write it.
  static func run(_ testCase: CardConformanceCase) async throws -> ConformanceJSON {
    let (store, apps) = try await store.value
    var testCase = testCase
    // The dataset's sources are the apps', in HealthKit.
    testCase.spec = filteringSources(testCase.spec, as: apps)
    let calendar = try testCase.calendar()
    let run = CardRun(
      spec: try testCase.cardSpec(), range: try testCase.cardRange(),
      date: try testCase.day(in: calendar), now: try testCase.nowDate(), calendar: calendar)
    let data = try await HealthKitCardEngine(store: store).data(run)
    return testCase.json(data, calendar: calendar)
  }

  struct NotWritten: Error, CustomStringConvertible {
    var written: [String: Int]
    var expected: [String: Int]
    var zoned: [String: Int]
    var expectedZoned: [String: Int]

    var description: String {
      """
      HealthKit holds \(written) samples and workouts by source app, \(zoned) with a time zone, \
      not the dataset's \(expected), \(expectedZoned) with one: run scripts/test-iphone-healthkit \
      HealthKitConformanceTests, whose source apps write them.
      """
    }
  }

  /// The spec with each series' `filter.sources` the apps that write those sources.
  static func filteringSources(_ spec: ConformanceJSON, as apps: [String: String])
    -> ConformanceJSON
  {
    guard case .object(var object) = spec, case .array(let series) = object["series"] else {
      return spec
    }
    object["series"] = .array(
      series.map { series in
        guard case .object(var series) = series, case .object(var filter) = series["filter"],
          case .array(let sources) = filter["sources"]
        else { return series }
        filter["sources"] = .array(
          sources.map { source in
            guard case .string(let source) = source else { return source }
            return .string(apps[source] ?? source)
          })
        series["filter"] = .object(filter)
        return .object(series)
      })
    return .object(object)
  }
}
