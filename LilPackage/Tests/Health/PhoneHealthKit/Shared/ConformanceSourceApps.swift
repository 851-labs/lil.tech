import Foundation

/// The apps that write the cards' conformance dataset into the simulator's HealthKit, one for each
/// of its sources (851-3201), since HealthKit gives every sample the source of the app that saved
/// it: the Watch's heart rate and sleep must be another source's than the iPhone's and the chest
/// strap's, for nights' sources, time weighting and filters. `scripts/test-iphone-healthkit` makes
/// them from the tests' host (`HealthKitTestHost`), as copies with these bundle IDs. Launched with
/// `-writeConformance`, app N writes the samples and workouts of `ConformanceSamples.sources[N − 1]`
/// (the dataset's sources, sorted), so their bundle IDs sort as the dataset's sources do, for
/// nights' ties; with `-deleteConformance`, it deletes what it wrote.
enum ConformanceSourceApps {
  /// Two digits, so ten or more still sort in order.
  static func bundleID(_ number: Int) -> String {
    "tech.lil.healthkit-source-" + (number < 10 ? "0\(number)" : "\(number)")
  }

  /// Which app a bundle ID is, from 1, or `nil` for any other app.
  static func number(of bundleID: String) -> Int? {
    guard bundleID.hasPrefix("tech.lil.healthkit-source-") else { return nil }
    return Int(bundleID.dropFirst("tech.lil.healthkit-source-".count))
  }

  /// Each of the dataset's sources, with the bundle ID of the app that writes its samples.
  static func apps(for sources: [String]) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: sources.enumerated().map { ($0.element, bundleID($0.offset + 1)) })
  }
}
