import Charts
import HealthDatabase
import SQLiteData
import SwiftUI

// MARK: State of Mind

/// State of Mind, as in Health: how pleasant each log felt over the last four weeks, then every
/// log by day with its feelings and what they were about. Follows the local database as sync
/// changes it.
struct StateOfMindView: View {
  @Fetch private var logs: [HealthStateOfMind]

  init() {
    _logs = Fetch(wrappedValue: [], RecentStateOfMindLogs(), scheduler: MainQueueScheduler())
  }

  var body: some View {
    StateOfMindContent(
      state: $logs.loadError.map { .failed($0.localizedDescription) }
        ?? ($logs.isLoading && logs.isEmpty ? .loading : .loaded(logs)),
      now: .now)
  }
}

struct RecentStateOfMindLogs: FetchKeyRequest {
  static let limit = 2_000

  func fetch(_ db: Database) throws -> [HealthStateOfMind] {
    try HealthDatabase.stateOfMindLogs(limit: Self.limit, db)
  }
}

/// What State of Mind shows, however it got it.
struct StateOfMindContent: View {
  enum State {
    case loading
    case loaded([HealthStateOfMind])
    case failed(String)
  }

  let state: State
  let now: Date
  var calendar = Calendar.current

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load State of Mind", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let logs) where logs.isEmpty:
        ContentUnavailableView(
          "No State of Mind Logs", systemImage: "brain.head.profile",
          description: Text(
            "How you feel, logged in the Health app or Mindfulness on Apple Watch, will appear here."
          ))
      case .loaded(let logs):
        List {
          Section("Last 4 Weeks") {
            ValenceChart(logs: logs, interval: lastFourWeeks)
              .frame(height: 220)
              .padding(.vertical, 8)
          }
          ForEach(days(logs), id: \.day) { section in
            Section(section.day.formatted(date: .complete, time: .omitted)) {
              ForEach(section.logs) { log in
                StateOfMindRow(log: log)
              }
            }
          }
        }
      }
    }
    .navigationTitle("State of Mind")
  }

  private var lastFourWeeks: DateInterval {
    let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    return DateInterval(start: calendar.date(byAdding: .day, value: -28, to: end) ?? end, end: end)
  }

  private func days(_ logs: [HealthStateOfMind]) -> [(day: Date, logs: [HealthStateOfMind])] {
    var days: [(day: Date, logs: [HealthStateOfMind])] = []
    for log in logs {
      let day = calendar.startOfDay(for: Date(unixMilliseconds: log.startDate))
      if days.last?.day == day {
        days[days.count - 1].logs.append(log)
      } else {
        days.append((day, [log]))
      }
    }
    return days
  }
}

/// Each log in the interval at how pleasant it felt, from very unpleasant to very pleasant.
struct ValenceChart: View {
  let logs: [HealthStateOfMind]
  let interval: DateInterval

  var body: some View {
    let shown = logs.filter { interval.contains(Date(unixMilliseconds: $0.startDate)) }
    Chart(shown) { log in
      PointMark(
        x: .value("Date", Date(unixMilliseconds: log.startDate)),
        y: .value("Valence", log.valence)
      )
      .foregroundStyle(MoodFormat.color(log.valence))
      .symbol(log.kind == 2 ? .square : .circle)
      .symbolSize(70)
    }
    .chartXScale(domain: interval.start...interval.end)
    .chartYScale(domain: -1...1)
    .chartYAxis {
      AxisMarks(position: .trailing, values: [-1, 0, 1]) { value in
        AxisGridLine()
        AxisValueLabel {
          if let valence = value.as(Double.self) {
            Text(valence > 0 ? "Very Pleasant" : valence < 0 ? "Very Unpleasant" : "Neutral")
          }
        }
      }
    }
    .overlay {
      if shown.isEmpty {
        Text("No Logs in the Last 4 Weeks")
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityLabel("How pleasant each log felt")
  }
}

/// A log: what kind, how it felt, its feelings and what they were about, and when.
struct StateOfMindRow: View {
  let log: HealthStateOfMind

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Circle()
        .fill(MoodFormat.color(log.valence))
        .frame(width: 14, height: 14)
        .padding(.top, 3)
      VStack(alignment: .leading, spacing: 2) {
        Text(log.decodedValenceClassification?.name ?? "Unknown")
          .font(.headline)
        Text(log.kindName)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        if !log.labelNames.isEmpty {
          Text(log.labelNames.joined(separator: ", "))
        }
        if !log.associationNames.isEmpty {
          Text(log.associationNames.joined(separator: ", "))
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Text(Date(unixMilliseconds: log.startDate).formatted(date: .omitted, time: .shortened))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

enum MoodFormat {
  /// From indigo (very unpleasant) through teal (neutral) to orange (very pleasant), as Health
  /// colors moods from cool to warm.
  static func color(_ valence: Double) -> Color {
    valence < -0.33
      ? .indigo
      : valence < 0
        ? .blue
        : valence <= 0.33
          ? .teal
          : valence < 0.66
            ? .yellow : .orange
  }
}

// MARK: Scored assessments

/// A questionnaire's history (GAD-7 or PHQ-9), as in Health: each score over its risk bands,
/// then every assessment with its risk. Follows the local database as sync changes it.
struct ScoredAssessmentsView: View {
  let kind: AssessmentKind
  let name: String
  @Fetch private var assessments: [HealthScoredAssessment]

  init(kind: AssessmentKind, name: String) {
    self.kind = kind
    self.name = name
    _assessments = Fetch(
      wrappedValue: [], RecentAssessments(type: kind.rawValue), scheduler: MainQueueScheduler())
  }

  var body: some View {
    ScoredAssessmentsContent(
      kind: kind, name: name,
      state: $assessments.loadError.map { .failed($0.localizedDescription) }
        ?? ($assessments.isLoading && assessments.isEmpty ? .loading : .loaded(assessments)))
  }
}

struct RecentAssessments: FetchKeyRequest {
  static let limit = 500
  let type: String

  func fetch(_ db: Database) throws -> [HealthScoredAssessment] {
    try HealthDatabase.scoredAssessments(of: type, limit: Self.limit, db)
  }
}

/// What an assessment's history shows, however it got it.
struct ScoredAssessmentsContent: View {
  enum State {
    case loading
    case loaded([HealthScoredAssessment])
    case failed(String)
  }

  let kind: AssessmentKind
  let name: String
  let state: State

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load \(name)", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let assessments) where assessments.isEmpty:
        ContentUnavailableView(
          "No Assessments", systemImage: "list.clipboard",
          description: Text("Questionnaires you take in the Health app will appear here."))
      case .loaded(let assessments):
        List {
          Section {
            AssessmentChart(kind: kind, assessments: assessments)
              .frame(height: 220)
              .padding(.vertical, 8)
          }
          Section("All Assessments") {
            ForEach(assessments) { assessment in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(kind.riskName(assessment.risk))
                    .font(.headline)
                  Text("Score \(assessment.score) of \(kind.maximumScore)")
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                  Date(unixMilliseconds: assessment.startDate).formatted(
                    date: .abbreviated, time: .omitted)
                )
                .foregroundStyle(.secondary)
              }
              .padding(.vertical, 4)
            }
          }
        }
      }
    }
    .navigationTitle(name)
  }
}

/// Each score over time, over the bands its risks start at.
struct AssessmentChart: View {
  let kind: AssessmentKind
  let assessments: [HealthScoredAssessment]

  var body: some View {
    let thresholds = kind.riskThresholds
    Chart {
      ForEach(thresholds.indices, id: \.self) { index in
        RectangleMark(
          yStart: .value("From", thresholds[index]),
          yEnd: .value(
            "To", index + 1 < thresholds.count ? thresholds[index + 1] : kind.maximumScore)
        )
        .foregroundStyle(.purple.opacity(0.04 + 0.04 * Double(index)))
      }
      ForEach(assessments.reversed()) { assessment in
        let date = Date(unixMilliseconds: assessment.startDate)
        LineMark(x: .value("Date", date), y: .value("Score", assessment.score))
          .foregroundStyle(.purple)
        PointMark(x: .value("Date", date), y: .value("Score", assessment.score))
          .foregroundStyle(.purple)
      }
    }
    .chartYScale(domain: 0...kind.maximumScore)
    .chartYAxis {
      AxisMarks(position: .trailing, values: thresholds + [kind.maximumScore])
    }
    .accessibilityLabel("Scores over time")
  }
}
