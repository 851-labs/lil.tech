#if targetEnvironment(simulator)
  import HealthKit
  import Observation
  import os
  import SwiftUI

  /// Made-up Health data for the simulator, to check sync end to end without anyone's real data
  /// (AGENTS.md). Simulator builds only: it writes to HealthKit, which the app otherwise never
  /// does.
  @MainActor @Observable
  final class SyntheticHealthData {
    static let shared = SyntheticHealthData()

    /// A year a time, before what's there already, so adding again makes a longer history.
    nonisolated static let days = 365
    /// Samples per save. Each save wakes the app's own observer, which recomputes a type's sums
    /// from the earliest sample saved to now, so few big saves rather than many small ones.
    nonisolated static let batchSize = 100_000

    private(set) var isAdding = false
    private(set) var saved: Int?
    private(set) var failure: String?

    private nonisolated static let logger = Logger(
      subsystem: "tech.lil.health", category: "SyntheticHealth")
    /// Where the year being added starts and ends, and how far each series got, so a run that
    /// stopped carries on rather than adding the same samples again.
    private nonisolated static let progressKey = "syntheticHealthDataProgress"

    private struct Progress: Codable {
      var start: Date
      var end: Date
      /// Each series' next sample time, by type identifier.
      var next: [String: Date] = [:]
    }

    /// About what an iPhone with a Watch records, in the same proportions: active energy every
    /// minute while awake, heart rate every 5 minutes, basal energy every 15, steps every 10.
    private nonisolated static let series:
      [(HKQuantityTypeIdentifier, HKUnit, interval: TimeInterval)] = [
        (.activeEnergyBurned, .kilocalorie(), 60),
        (.heartRate, .count().unitDivided(by: .minute()), 5 * 60),
        (.basalEnergyBurned, .kilocalorie(), 15 * 60),
        (.stepCount, .count(), 10 * 60),
      ]

    /// Adds a year of samples ending where the last ones started (or now), or finishes one that
    /// stopped partway. It runs on its own, whatever happens to the view that started it.
    func add() {
      guard !isAdding else { return }
      isAdding = true
      failure = nil
      saved = 0
      Task.detached(priority: .userInitiated) {
        do {
          let count = try await Self.write { count in await MainActor.run { self.saved = count } }
          Self.logger.info("Added \(count) synthetic samples")
        } catch {
          Self.logger.error("Adding synthetic samples failed: \(error)")
          await MainActor.run { self.failure = error.localizedDescription }
        }
        await MainActor.run { self.isAdding = false }
      }
    }

    private nonisolated static func write(
      progress report: @escaping @Sendable (Int) async -> Void
    ) async throws -> Int {
      let store = HKHealthStore()
      try await store.requestAuthorization(
        toShare: Set(series.map { HKQuantityType($0.0) }), read: [])
      let defaults = UserDefaults.standard
      var progress: Progress
      if let saved = defaults.data(forKey: progressKey),
        let resumed = try? JSONDecoder().decode(Progress.self, from: saved)
      {
        progress = resumed
      } else {
        // Before the earliest sample it added, as Health has it: kept across reinstalls.
        let end = try await earliestSample(in: store) ?? .now
        progress = Progress(start: end.addingTimeInterval(-Double(days) * 86_400), end: end)
      }
      let calendar = Calendar.current
      var generator = SystemRandomNumberGenerator()
      var saved = 0
      for (identifier, unit, interval) in series {
        let type = HKQuantityType(identifier)
        var time = progress.next[identifier.rawValue] ?? progress.start
        var batch: [HKObject] = []
        func save() async throws {
          try await store.save(batch)
          saved += batch.count
          batch.removeAll(keepingCapacity: true)
          progress.next[identifier.rawValue] = time
          defaults.set(try JSONEncoder().encode(progress), forKey: progressKey)
          logger.info("Saved \(saved) synthetic samples")
          await report(saved)
        }
        while time < progress.end {
          let hour = calendar.component(.hour, from: time)
          // Awake from 7:00 to 23:00, except heart rate and basal energy, around the clock.
          let awake = (7..<23).contains(hour)
          if awake || identifier == .heartRate || identifier == .basalEnergyBurned {
            let value: Double =
              switch identifier {
              case .heartRate: Double.random(in: awake ? 60...110 : 48...65, using: &generator)
              case .stepCount: Double(Int.random(in: 0...900, using: &generator))
              case .basalEnergyBurned: Double.random(in: 15...20, using: &generator)
              default: Double.random(in: 0.2...6, using: &generator)
              }
            let end = time.addingTimeInterval(identifier == .heartRate ? 0 : interval)
            batch.append(
              HKQuantitySample(
                type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: time,
                end: end))
          }
          time.addTimeInterval(interval)
          if batch.count == batchSize { try await save() }
        }
        if !batch.isEmpty { try await save() }
        progress.next[identifier.rawValue] = progress.end
        defaults.set(try JSONEncoder().encode(progress), forKey: progressKey)
      }
      defaults.removeObject(forKey: progressKey)
      return saved
    }

    /// When the earliest sample this app added starts, if there's one.
    private nonisolated static func earliestSample(in store: HKHealthStore) async throws -> Date? {
      let descriptor = HKSampleQueryDescriptor(
        predicates: series.map {
          .quantitySample(
            type: HKQuantityType($0.0), predicate: HKQuery.predicateForObjects(from: .default()))
        },
        sortDescriptors: [SortDescriptor(\.startDate, order: .forward)], limit: 1)
      return try await descriptor.result(for: store).first?.startDate
    }
  }

  /// The account section's button for `SyntheticHealthData`.
  struct SyntheticHealthSection: View {
    let data = SyntheticHealthData.shared

    var body: some View {
      Section {
        Button(data.isAdding ? "Adding Synthetic Health Data…" : "Add Synthetic Health Data") {
          data.add()
        }
        .disabled(data.isAdding)
      } header: {
        Text("Simulator")
      } footer: {
        if let failure = data.failure {
          Text(failure)
        } else if let saved = data.saved {
          Text("\(saved.formatted()) samples saved")
        } else {
          Text("Adds a year of made-up samples to Health, before any it added already.")
        }
      }
    }
  }
#endif
