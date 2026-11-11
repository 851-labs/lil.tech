import AppKit
import CoreLocation
import Foundation
import HealthCatalog
import HealthDatabase
import SQLiteData
import SwiftUI
import Testing

@testable import HealthPages

private let metric = Locale(identifier: "en_US@measure=metric")
private let us = Locale(identifier: "en_US")
private let uk = Locale(identifier: "en_GB")

/// A synthetic 26-minute workout.
private func workout(metadata: String? = nil) -> HealthWorkout {
  HealthWorkout(
    id: "run", activityType: 37, startDate: 1_760_400_000_000, endDate: 1_760_401_560_000,
    duration: 1_560, activities: "[]", events: "[]", statistics: "{}", sourceName: "Watch",
    sourceBundleID: "com.example.watch", metadata: metadata)
}

struct WorkoutFormatTests {
  @Test
  func timesAndPacesReadLikeHealth() {
    #expect(WorkoutFormat.duration(42 * 60 + 18) == "42:18")
    #expect(WorkoutFormat.duration(3600 + 2 * 60 + 5) == "1:02:05")
    let km = WorkoutFormat.splitUnit(locale: metric)
    #expect(WorkoutFormat.pace(5 * 60 + 12, over: 1000, in: km) == "5'12\"/km")
    #expect(WorkoutActivity.name(37) == "Running")
    #expect(WorkoutActivity.name(65) == "Kickboxing")
    #expect(WorkoutActivity.name(9_999) == "Workout")
  }

  /// In the locale's units (851-3176): km or mi, per km or per mi, a swim in m or yd. Energy
  /// stays in kcal.
  @Test
  func distancesAndPacesAreInTheLocalesUnits() {
    let run = [
      "HKQuantityTypeIdentifierDistanceWalkingRunning": WorkoutStatistic(unit: "m", sum: 5_020)
    ]
    let headline = {
      (statistics: [String: WorkoutStatistic], locale: Locale, metadata: String?) in
      WorkoutFormat.headline(workout(metadata: metadata), statistics, locale: locale)
    }
    #expect(headline(run, metric, nil) == "5.02 km")
    #expect(headline(run, us, nil) == "3.12 mi")
    #expect(headline(run, uk, nil) == "3.12 mi")
    #expect(headline(run, Locale(identifier: "de_DE"), nil) == "5,02 km")
    // Cycling's too.
    let ride = ["HKQuantityTypeIdentifierDistanceCycling": WorkoutStatistic(unit: "m", sum: 32_187)]
    #expect(headline(ride, us, nil) == "20.00 mi")
    // A swim's, as Health shows it: in the pool's unit, whatever the locale, or else yards in
    // the US and metres in the UK.
    let swim = ["HKQuantityTypeIdentifierDistanceSwimming": WorkoutStatistic(unit: "m", sum: 1_500)]
    #expect(headline(swim, metric, nil) == "1,500 m")
    #expect(headline(swim, uk, nil) == "1,500 m")
    #expect(headline(swim, us, nil) == "1,640 yd")
    let yardPool = #"{"HKLapLength":"25 yd","HKSwimmingLocationType":1}"#
    let metrePool = #"{"HKLapLength":"50 m","HKSwimmingLocationType":1}"#
    #expect(headline(swim, metric, yardPool) == "1,640 yd")
    #expect(headline(swim, us, metrePool) == "1,500 m")
    #expect(headline(swim, Locale(identifier: "de_DE"), metrePool) == "1.500 m")
    // Without a distance, energy.
    let energy = [
      "HKQuantityTypeIdentifierActiveEnergyBurned": WorkoutStatistic(unit: "kcal", sum: 1_234.4)
    ]
    #expect(headline(energy, us, nil) == "1,234 kcal")
    // 5 km in 26 minutes: 5'12" a kilometer, 8'22" a mile.
    let mi = WorkoutFormat.splitUnit(locale: us)
    #expect(
      WorkoutFormat.pace(26 * 60, over: 5_000, in: WorkoutFormat.splitUnit(locale: metric))
        == "5'12\"/km")
    #expect(WorkoutFormat.pace(26 * 60, over: 5_000, in: mi) == "8'22\"/mi")
    #expect(WorkoutFormat.distance(1_609.344, in: mi) == "1.00 mi")
  }

  /// Splits are recomputed per mile in the US and UK, not kilometers relabelled.
  @Test
  func splitsArePerMileWhereMilesAre() {
    // Synthetic: about 4 km due north at 4 m/s.
    let start = Date(timeIntervalSince1970: 1_760_400_000)
    let locations = (0...40).map { index in
      RouteLocation(
        time: start.addingTimeInterval(Double(index) * 25), latitude: Double(index) * 0.0009,
        longitude: 0, altitude: 0, speed: 4)
    }
    let miles = WorkoutFormat.splits(locations, pauses: [], in: WorkoutFormat.splitUnit(locale: us))
    #expect(miles.count == 3)
    #expect(miles.dropLast().allSatisfy { abs($0.distance - 1_609.344) < 1e-6 })
    // A mile at 4 m/s is about 402 seconds.
    #expect(abs(miles[0].duration - 402) < 2)
    let kilometers = WorkoutFormat.splits(
      locations, pauses: [], in: WorkoutFormat.splitUnit(locale: metric))
    #expect(kilometers.count == 5)
    #expect(kilometers.first?.distance == 1_000)
  }

  /// Names come from the catalog and symbols from here, so each activity needs both.
  @Test
  func everyNamedActivityHasASymbol() {
    #expect(Set(WorkoutActivity.symbols.keys) == Set(HealthCatalog.workoutActivityNames.keys))
  }

  /// A misspelled symbol draws nothing, without an error.
  @Test
  func everySymbolExists() {
    for (activityType, symbol) in WorkoutActivity.symbols {
      #expect(
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
        "\(activityType): no SF Symbol \(symbol)")
    }
  }

  // Main actor: resolving a SwiftUI color to an NSColor needs it.
  @Test @MainActor
  func theRouteIsGreenWhereFastAndRedWhereSlow() {
    // Synthetic: fast for the first half, slow for the second.
    let start = Date(timeIntervalSince1970: 1_760_400_000)
    let locations = (0..<200).map { index in
      RouteLocation(
        time: start.addingTimeInterval(Double(index)), latitude: 0, longitude: Double(index) * 1e-4,
        altitude: 0, speed: index < 100 ? 5 : 2)
    }
    let pieces = RouteMap.pieces(locations)
    #expect(pieces.count > 10)
    // Every location is in a piece, and pieces join end to start.
    #expect(pieces.first?.coordinates.first?.longitude == 0)
    #expect(pieces.last?.coordinates.last?.longitude == locations.last?.longitude)
    let hue = { (color: Color) in NSColor(color).usingColorSpace(.deviceRGB)?.hueComponent ?? -1 }
    #expect(hue(pieces.first!.color) > 0.3)
    // Unknown speeds aren't slow.
    let unknown = (0..<50).map { index in
      RouteLocation(
        time: start.addingTimeInterval(Double(index)), latitude: 0, longitude: Double(index) * 1e-4,
        altitude: 0, speed: index.isMultiple(of: 2) ? -1 : 5)
    }
    let known = (0..<50).map { index in
      RouteLocation(
        time: start.addingTimeInterval(Double(index)), latitude: 0, longitude: Double(index) * 1e-4,
        altitude: 0, speed: index < 25 ? 2 : 5)
    }
    let mixed = RouteMap.pieces(known + unknown)
    #expect(hue(mixed.last!.color) > 0.3)
    // Red's hue is 0, or 1 as it wraps around.
    let slow = hue(pieces.last!.color)
    #expect(min(slow, 1 - slow) < 0.05)
  }
}

struct WorkoutHeartRateTests {
  // Main actor: it's the view's.
  @Test @MainActor
  func theChartUsesTheMainSource() {
    let sample = { (source: String, value: Double) in
      HealthSample(
        id: UUID().uuidString, type: "HKQuantityTypeIdentifierHeartRate", startDate: 0,
        endDate: 0, value: value, unit: "count/min", sourceName: source, sourceBundleID: source)
    }
    let samples = [
      sample("watch", 150), sample("strap", 90), sample("watch", 152), sample("watch", 149),
    ]
    #expect(HealthDatabase.mainSource(samples).map(\.value) == [150, 152, 149])
  }

  /// The chart is the heart rate linked to the workout (851-4186), even another source's, and
  /// not what else was recorded during it; until its links sync, the main source's during it.
  @Test
  func theChartUsesTheLinkedSamples() throws {
    let database = try HealthDatabase.make()
    let workout = HealthWorkout(
      id: "w", activityType: 37, startDate: 0, endDate: 60_000, duration: 60, activities: "[]",
      events: "[]", statistics: "{}", sourceName: "Test", sourceBundleID: "com.example")
    let sample = { (id: String, source: String, at: Int) in
      HealthSample(
        id: id, type: WorkoutFormat.heartRate, startDate: at, endDate: at, value: 120,
        unit: "count/min", sourceName: source, sourceBundleID: source)
    }
    try database.write { db in
      try HealthSample.insert {
        sample("w1", "watch", 1_000)
        sample("w2", "watch", 2_000)
        sample("w3", "watch", 3_000)
        sample("s1", "strap", 1_500)
      }
      .execute(db)
    }
    let guessed = try database.read { db in try WorkoutLinkedDataRequest(workout: workout).fetch(db)
    }
    #expect(guessed.heartRates.samples.map(\.id) == ["w1", "w2", "w3"])
    #expect(guessed.heartRates.origin == .notSynced)
    try database.write { db in
      try HealthWorkoutSamples.insert {
        HealthWorkoutSamples(
          id: "w", count: 1, samples: #"{"\#(WorkoutFormat.heartRate)":["s1"]}"#)
      }
      .execute(db)
    }
    let linked = try database.read { db in try WorkoutLinkedDataRequest(workout: workout).fetch(db)
    }
    #expect(linked.heartRates.samples.map(\.id) == ["s1"])
    #expect(linked.heartRates.origin == .linked)
    try database.write { db in
      try HealthWorkoutSamples.upsert {
        HealthWorkoutSamples(id: "w", count: 30_000, samples: nil)
      }
      .execute(db)
    }
    let tooMany = try database.read { db in try WorkoutLinkedDataRequest(workout: workout).fetch(db)
    }
    #expect(tooMany.heartRates.samples.map(\.id) == ["w1", "w2", "w3"])
    #expect(tooMany.heartRates.origin == .tooMany)
  }

  @Test
  func effortScoresAreRatedAsHealthRatesThem() {
    let score = { (value: Double?, type: String) in
      HealthSample(
        id: "e", type: type, startDate: 0, endDate: 0, value: value, unit: "appleEffortScore",
        sourceName: "Test", sourceBundleID: "com.example")
    }
    let rated = HealthDatabase.workoutEffortScoreType
    #expect(WorkoutFormat.effort(score(2, rated)) == "2 · Easy")
    #expect(WorkoutFormat.effort(score(6.4, rated)) == "6 · Moderate")
    #expect(WorkoutFormat.effort(score(8, rated)) == "8 · Hard")
    #expect(WorkoutFormat.effort(score(10, rated)) == "10 · All Out")
    #expect(WorkoutFormat.effort(score(0, rated)) == "0")
    #expect(WorkoutFormat.effort(score(nil, rated)) == nil)
    #expect(WorkoutFormat.effortLabel(score(5, rated)) == "Effort")
    #expect(
      WorkoutFormat.effortLabel(score(5, HealthDatabase.estimatedWorkoutEffortScoreType))
        == "Est. Effort")
  }
}
