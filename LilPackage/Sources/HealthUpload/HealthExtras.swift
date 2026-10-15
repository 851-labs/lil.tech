public import Dependencies
public import Foundation
import HealthKit
import IssueReporting

// What isn't a sample, so has no anchors: characteristics and Activity summaries. The backfill
// reads them on every run of everything (`HealthBackfill.uploadExtras`).

extension DependencyValues {
  public var healthCharacteristicsReader: HealthCharacteristicsReader {
    get { self[HealthCharacteristicsReader.self] }
    set { self[HealthCharacteristicsReader.self] = newValue }
  }

  public var healthActivitySummaryReader: HealthActivitySummaryReader {
    get { self[HealthActivitySummaryReader.self] }
    set { self[HealthActivitySummaryReader.self] = newValue }
  }
}

/// Reads the characteristics Health lets this app read: date of birth, sex, blood type, skin
/// type, wheelchair use and Activity move mode.
public struct HealthCharacteristicsReader: Sendable {
  public var read: @Sendable () async throws -> [HealthMutation]

  public init(read: @escaping @Sendable () async throws -> [HealthMutation]) {
    self.read = read
  }
}

extension HealthCharacteristicsReader: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    return Self {
      // Each read throws when the app may not read that characteristic; those are left out.
      var mutations: [HealthMutation] = []
      if let birth = try? store.dateOfBirthComponents() {
        mutations.append(
          HealthEncoder.characteristic(.dateOfBirth, value: HealthEncoder.dateOfBirth(birth)))
      }
      if let sex = try? store.biologicalSex() {
        mutations.append(
          HealthEncoder.characteristic(
            .biologicalSex, value: HealthEncoder.biologicalSex(sex.biologicalSex)))
      }
      if let blood = try? store.bloodType() {
        mutations.append(
          HealthEncoder.characteristic(
            .bloodType, value: HealthEncoder.bloodType(blood.bloodType)))
      }
      if let skin = try? store.fitzpatrickSkinType() {
        mutations.append(
          HealthEncoder.characteristic(
            .fitzpatrickSkinType, value: HealthEncoder.skinType(skin.skinType)))
      }
      if let wheelchair = try? store.wheelchairUse() {
        mutations.append(
          HealthEncoder.characteristic(
            .wheelchairUse, value: HealthEncoder.wheelchairUse(wheelchair.wheelchairUse)))
      }
      if let move = try? store.activityMoveMode() {
        mutations.append(
          HealthEncoder.characteristic(
            .activityMoveMode, value: HealthEncoder.activityMoveMode(move.activityMoveMode)))
      }
      return mutations
    }
  }

  public static var testValue: Self {
    Self {
      reportIssue("Unimplemented: @Dependency(\\.healthCharacteristicsReader).read")
      return []
    }
  }
}

/// Reads Activity summaries, one per day.
public struct HealthActivitySummaryReader: Sendable {
  /// The summaries for the days from `from`'s day through today, or all of them if it's `nil`.
  public var read: @Sendable (_ from: Date?) async throws -> [HealthMutation]

  public init(read: @escaping @Sendable (_ from: Date?) async throws -> [HealthMutation]) {
    self.read = read
  }
}

extension HealthActivitySummaryReader: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    return Self { from in
      // Activity summaries are days in the user's calendar, as the Fitness app shows them.
      let calendar = Calendar.current
      let predicate = from.map { from in
        let units: Set<Calendar.Component> = [.era, .year, .month, .day]
        var start = calendar.dateComponents(units, from: from)
        var end = calendar.dateComponents(units, from: Date())
        start.calendar = calendar
        end.calendar = calendar
        return HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)
      }
      let summaries: [HKActivitySummary]
      do {
        summaries = try await HKActivitySummaryQueryDescriptor(predicate: predicate).result(
          for: store)
      } catch let error as HKError where error.code == .errorDatabaseInaccessible {
        throw HealthReader.Locked()
      }
      return summaries.compactMap { summary in
        HealthEncoder.activitySummary(
          summary, day: summary.dateComponents(for: calendar), calendar: calendar)
      }
    }
  }

  public static var testValue: Self {
    Self { _ in
      reportIssue("Unimplemented: @Dependency(\\.healthActivitySummaryReader).read")
      return []
    }
  }
}
