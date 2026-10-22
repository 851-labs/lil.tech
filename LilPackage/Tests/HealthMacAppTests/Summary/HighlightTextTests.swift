import Foundation
import HealthCatalog
import HealthDatabase
import Testing

@testable import HealthMacApp

struct HighlightTextTests {
  private let steps = HealthCatalog.type(id: "HKQuantityTypeIdentifierStepCount")!
  private let resting = HealthCatalog.type(id: "HKQuantityTypeIdentifierRestingHeartRate")!

  @Test
  func weeksSayWhichWayTheyWent() {
    let up = Highlight(
      typeID: steps.id, kind: .week, current: 8_000, previous: 7_000, recentStart: .now)
    #expect(HighlightText.sentence(up, type: steps).contains("a day"))
    #expect(HighlightText.sentence(up, type: steps).contains("up from"))
    let same = Highlight(
      typeID: steps.id, kind: .week, current: 7_100, previous: 7_000, recentStart: .now)
    #expect(HighlightText.sentence(same, type: steps).contains("about the same"))
  }

  @Test
  func fromNothingIsAChange() {
    let exercise = HealthCatalog.type(id: "HKQuantityTypeIdentifierAppleExerciseTime")!
    let fromZero = Highlight(
      typeID: exercise.id, kind: .week, current: 30, previous: 0, recentStart: .now)
    #expect(fromZero.direction == .up)
    #expect(HighlightText.sentence(fromZero, type: exercise).contains("up from 0 min"))
  }

  @Test
  func eachValueKeepsItsOwnUnit() {
    let distance = HealthCatalog.type(id: "HKQuantityTypeIdentifierDistanceWalkingRunning")!
    let highlight = Highlight(
      typeID: distance.id, kind: .week, current: 5_200, previous: 950, recentStart: .now)
    let sentence = HighlightText.sentence(highlight, type: distance)
    #expect(sentence.contains("km a day"))
    #expect(sentence.contains("950 m"))
  }

  @Test
  func trendsFollowTheValues() {
    let down = Highlight(
      typeID: resting.id, kind: .trend, current: 58, previous: 66, recentStart: .now)
    #expect(down.direction == .down)
    #expect(HighlightText.sentence(down, type: resting).contains("trending down"))
    // A discrete type's average isn't per day.
    #expect(!HighlightText.sentence(down, type: resting).contains("a day"))
  }
}
