import HealthCatalog
import HealthDatabase
import SQLiteData
public import SwiftUI

/// Workouts, newest first and grouped by month, as in Health. Each opens its detail. Follows the
/// local database as sync changes it.
public struct WorkoutsView: View {
  @Fetch private var workouts: [HealthWorkout]

  public init() {
    _workouts = Fetch(
      wrappedValue: [], RecentWorkouts(), scheduler: MainQueueScheduler())
  }

  public var body: some View {
    WorkoutsContent(
      state: $workouts.loadError.map { .failed($0.localizedDescription) }
        ?? ($workouts.isLoading && workouts.isEmpty ? .loading : .loaded(workouts)))
  }
}

/// The most recent workouts: years of them for most people.
struct RecentWorkouts: FetchKeyRequest {
  static let limit = 2_000

  func fetch(_ db: Database) throws -> [HealthWorkout] {
    try HealthDatabase.workouts(limit: Self.limit, db)
  }
}

/// What Workouts shows, however it got it.
struct WorkoutsContent: View {
  enum State {
    case loading
    case loaded([HealthWorkout])
    case failed(String)
  }

  let state: State
  var calendar = Calendar.current

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load Workouts", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let workouts) where workouts.isEmpty:
        ContentUnavailableView(
          "No Workouts", systemImage: "figure.run",
          description: Text("Workouts from your Apple Watch and fitness apps will appear here."))
      case .loaded(let workouts):
        List {
          ForEach(
            monthSections(workouts, calendar: calendar, startDate: \.startDate), id: \.month
          ) { section in
            Section(section.month.formatted(.dateTime.month(.wide).year())) {
              ForEach(section.records) { workout in
                NavigationLink {
                  WorkoutDetailView(workout: workout)
                } label: {
                  WorkoutRow(workout: workout)
                }
              }
            }
          }
          if workouts.count >= RecentWorkouts.limit {
            Text("Showing the \(RecentWorkouts.limit.formatted()) most recent workouts.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .navigationTitle("Workouts")
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
