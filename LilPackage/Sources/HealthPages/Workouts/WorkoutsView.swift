import Dependencies
import HealthCatalog
import HealthDatabase
import SQLiteData
public import SwiftUI

/// Workouts, newest first and grouped by month, as in Health. Each opens its detail. Follows the
/// local database as sync changes it.
///
/// With `onlyWithRoutes`, it's Workout Routes (851-2835): the workouts with a route, then the
/// routes no workout shows, each opening on a map.
public struct WorkoutsView: View {
  private let onlyWithRoutes: Bool
  @Fetch private var list: WorkoutList

  public init(onlyWithRoutes: Bool = false) {
    self.onlyWithRoutes = onlyWithRoutes
    _list = Fetch(
      wrappedValue: WorkoutList(), RecentWorkouts(onlyWithRoutes: onlyWithRoutes),
      scheduler: MainQueueScheduler())
  }

  public var body: some View {
    WorkoutsContent(
      state: $list.loadError.map { .failed($0.localizedDescription) }
        ?? ($list.isLoading && list.isEmpty
          ? .loading : .loaded(list.workouts, otherRoutes: list.otherRoutes)),
      onlyWithRoutes: onlyWithRoutes)
  }
}

/// What Workouts lists.
struct WorkoutList: Equatable, Sendable {
  var workouts: [HealthWorkout] = []
  /// Routes no workout shows, for Workout Routes.
  var otherRoutes: [HealthWorkoutRoute] = []

  var isEmpty: Bool { workouts.isEmpty && otherRoutes.isEmpty }
}

/// The most recent workouts (years of them for most people), or those with routes, and the
/// routes no workout shows.
struct RecentWorkouts: FetchKeyRequest {
  static let limit = 2_000

  var onlyWithRoutes = false

  func fetch(_ db: Database) throws -> WorkoutList {
    guard onlyWithRoutes else {
      return WorkoutList(workouts: try HealthDatabase.workouts(limit: Self.limit, db))
    }
    let (workouts, otherRoutes) = try HealthDatabase.workoutRoutes(limit: Self.limit, db)
    return WorkoutList(workouts: workouts, otherRoutes: otherRoutes)
  }
}

/// What Workouts shows, however it got it.
struct WorkoutsContent: View {
  enum State {
    case loading
    case loaded([HealthWorkout], otherRoutes: [HealthWorkoutRoute] = [])
    case failed(String)
  }

  let state: State
  /// Workout Routes rather than Workouts.
  var onlyWithRoutes = false
  /// From dependencies, so snapshot catalogs fix it (`previewCalendar`).
  @Dependency(\.calendar) private var calendar

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          onlyWithRoutes ? "Couldn't Load Workout Routes" : "Couldn't Load Workouts",
          systemImage: "exclamationmark.triangle", description: Text(reason))
      case .loaded(let workouts, let otherRoutes) where workouts.isEmpty && otherRoutes.isEmpty:
        if onlyWithRoutes {
          ContentUnavailableView(
            "No Workout Routes", systemImage: "map",
            description: Text("Routes from your outdoor workouts will appear here."))
        } else {
          ContentUnavailableView(
            "No Workouts", systemImage: "figure.run",
            description: Text("Workouts from your Apple Watch and fitness apps will appear here."))
        }
      case .loaded(let workouts, let otherRoutes):
        let months = monthSections(workouts, calendar: calendar, startDate: \.startDate)
        List {
          ForEach(months, id: \.month) { section in
            Section {
              ForEach(section.records) { workout in
                NavigationLink {
                  WorkoutDetailView(workout: workout)
                } label: {
                  WorkoutRow(workout: workout)
                }
              }
            } header: {
              Text(section.month.formatted(.dateTime.month(.wide).year()))
            } footer: {
              // Under the workouts, not at the end of the page, which Other Routes may follow.
              if section.month == months.last?.month, workouts.count >= RecentWorkouts.limit {
                limitNote(onlyWithRoutes ? "workouts with routes" : "workouts")
              }
            }
          }
          if !otherRoutes.isEmpty {
            Section {
              ForEach(otherRoutes) { route in
                NavigationLink {
                  RouteDetailView(route: route)
                } label: {
                  OtherRouteRow(route: route)
                }
              }
            } header: {
              Text("Other Routes")
            } footer: {
              if otherRoutes.count >= RecentWorkouts.limit {
                limitNote("other routes")
              }
            }
          }
        }
      }
    }
    .navigationTitle(onlyWithRoutes ? "Workout Routes" : "Workouts")
  }

  /// That a list stops at the limit: "Showing the 2,000 most recent workouts."
  private func limitNote(_ what: String) -> some View {
    Text("Showing the \(RecentWorkouts.limit.formatted()) most recent \(what).")
      .font(.footnote)
      .foregroundStyle(.secondary)
  }
}

/// Records (newest first) by the month they started in, as Health lists workouts and ECGs.
func monthSections<Record>(
  _ records: [Record], calendar: Calendar, startDate: (Record) -> Int
) -> [(month: Date, records: [Record])] {
  sections(records, by: .month, calendar: calendar, startDate: startDate)
    .map { (month: $0.start, records: $0.records) }
}

/// Records (newest first) by the `component` (day, month…) they started in.
func sections<Record>(
  _ records: [Record], by component: Calendar.Component, calendar: Calendar,
  startDate: (Record) -> Int
) -> [(start: Date, records: [Record])] {
  var sections: [(start: Date, records: [Record])] = []
  for record in records {
    let start = Date(unixMilliseconds: startDate(record))
    let section = calendar.dateInterval(of: component, for: start)?.start ?? start
    if sections.last?.start == section {
      sections[sections.count - 1].records.append(record)
    } else {
      sections.append((section, [record]))
    }
  }
  return sections
}

/// A workout in the list: its activity, the figure that matters most for it, and when.
struct WorkoutRow: View {
  let workout: HealthWorkout

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: WorkoutActivity.symbol(workout.activityType))
        .font(.title3)
        .foregroundStyle(.green)
        .frame(width: 36, height: 36)
        .background(.green.opacity(0.15), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(WorkoutActivity.name(workout.activityType))
          .font(.headline)
        Text(WorkoutFormat.headline(workout, workout.decodedStatistics))
          .font(.system(.title3, design: .rounded).weight(.semibold))
          .foregroundStyle(.green)
      }
      Spacer()
      Text(Date(unixMilliseconds: workout.startDate).formatted(date: .abbreviated, time: .omitted))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

/// How workouts' figures read.
enum WorkoutFormat {
  static let activeEnergy = HealthWorkout.activeEnergyType
  static let basalEnergy = "HKQuantityTypeIdentifierBasalEnergyBurned"
  static let heartRate = HealthWorkout.heartRateType

  /// The workout's distance in meters, whichever kind it recorded.
  static func distance(_ statistics: [String: WorkoutStatistic]) -> Double? {
    HealthWorkout.distance(in: statistics)
  }

  /// Distance if it has one, otherwise active energy, otherwise its time.
  static func headline(_ workout: HealthWorkout, _ statistics: [String: WorkoutStatistic])
    -> String
  {
    if let meters = distance(statistics), meters > 0 {
      return (meters / 1000).formatted(.number.precision(.fractionLength(2))) + " km"
    }
    if let energy = statistics[activeEnergy]?.sum, energy > 0 {
      return "\(Int(energy.rounded())) kcal"
    }
    return duration(workout.duration)
  }

  /// "0:42:18", or "42:18" under an hour, as Health shows workout times.
  static func duration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest)
      : String(format: "%d:%02d", minutes, rest)
  }

  /// "5'12\"/km".
  static func pace(_ secondsPerKilometer: TimeInterval) -> String {
    let total = Int(secondsPerKilometer.rounded())
    return String(format: "%d'%02d\"/km", total / 60, total % 60)
  }
}
