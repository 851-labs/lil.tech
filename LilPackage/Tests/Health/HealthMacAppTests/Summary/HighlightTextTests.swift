import Foundation
import HealthCatalog
import HealthDatabase
import Testing

@testable import HealthMacApp

/// en_US's formats, with metric units, as the snapshot catalogs use.
private let metric = Locale(identifier: "en_US@measure=metric")

struct HighlightTextTests {
  private let steps = HealthCatalog.type(id: "HKQuantityTypeIdentifierStepCount")!
  private let resting = HealthCatalog.type(id: "HKQuantityTypeIdentifierRestingHeartRate")!

  @Test
  func weeksSayWhichWayTheyWent() {
    let up = Highlight(
      typeID: steps.id, kind: .week, current: 8_000, previous: 7_000, recentStart: .now)
    #expect(HighlightText.sentence(up, type: steps, locale: metric).contains("a day"))
    #expect(HighlightText.sentence(up, type: steps, locale: metric).contains("up from"))
    let same = Highlight(
      typeID: steps.id, kind: .week, current: 7_100, previous: 7_000, recentStart: .now)
    #expect(HighlightText.sentence(same, type: steps, locale: metric).contains("about the same"))
  }

  @Test
  func fromNothingIsAChange() {
    let exercise = HealthCatalog.type(id: "HKQuantityTypeIdentifierAppleExerciseTime")!
    let fromZero = Highlight(
      typeID: exercise.id, kind: .week, current: 30, previous: 0, recentStart: .now)
    #expect(fromZero.direction == .up)
    #expect(
      HighlightText.sentence(fromZero, type: exercise, locale: metric).contains("up from 0 min"))
  }

  /// Both weeks in the type's unit, as Health shows it, even under 1 km (851-3105).
  @Test
  func bothValuesInTheTypesUnit() {
    let distance = HealthCatalog.type(id: "HKQuantityTypeIdentifierDistanceWalkingRunning")!
    let highlight = Highlight(
      typeID: distance.id, kind: .week, current: 5_200, previous: 950, recentStart: .now)
    let sentence = HighlightText.sentence(highlight, type: distance, locale: metric)
    #expect(sentence.contains("5.2 km a day"))
    #expect(sentence.contains("0.95 km the week before"))
  }

  /// In the locale's units (851-3116).
  @Test
  func valuesInTheLocalesUnits() {
    let distance = HealthCatalog.type(id: "HKQuantityTypeIdentifierDistanceWalkingRunning")!
    let highlight = Highlight(
      typeID: distance.id, kind: .week, current: 8_046.72, previous: 3_218.688, recentStart: .now)
    let sentence = HighlightText.sentence(
      highlight, type: distance, locale: Locale(identifier: "en_US"))
    #expect(sentence.contains("5 mi a day"))
    #expect(sentence.contains("2 mi the week before"))
  }

  @Test
  func trendsFollowTheValues() {
    let down = Highlight(
      typeID: resting.id, kind: .trend, current: 58, previous: 66, recentStart: .now)
    #expect(down.direction == .down)
    #expect(HighlightText.sentence(down, type: resting, locale: metric).contains("trending down"))
    // A discrete type's average isn't per day.
    #expect(!HighlightText.sentence(down, type: resting, locale: metric).contains("a day"))
  }
}
