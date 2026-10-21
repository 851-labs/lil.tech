import Charts
import Dependencies
import HealthCatalog
public import HealthDatabase
import HealthUI
import SQLiteData
public import SwiftUI

/// A kind of Health notification (high heart rate, noise, walking steadiness…), newest first and
/// grouped by month, each with what it said (851-2829). Each opens its detail. Follows the local
/// database as sync changes it.
public struct HealthNotificationsView: View {
  let kind: HealthNotificationKind
  @Fetch private var notifications: [HealthSample]

  public init(kind: HealthNotificationKind) {
    self.kind = kind
    _notifications = Fetch(
      wrappedValue: [], RecentNotifications(kind: kind), scheduler: MainQueueScheduler())
  }

  public var body: some View {
    HealthNotificationsContent(
      kind: kind,
      state: $notifications.loadError.map { .failed($0.localizedDescription) }
        ?? ($notifications.isLoading && notifications.isEmpty
          ? .loading : .loaded(notifications)))
  }
}

/// A kind's most recent notifications: a few a year for most people.
struct RecentNotifications: FetchKeyRequest {
  static let limit = 1_000
  let kind: HealthNotificationKind

  func fetch(_ db: Database) throws -> [HealthSample] {
    try HealthDatabase.notifications(of: kind, limit: Self.limit, db)
  }
}

/// What a kind's notifications show, however it got them.
struct HealthNotificationsContent: View {
  enum State {
    case loading
    case loaded([HealthSample])
    case failed(String)
  }

  let kind: HealthNotificationKind
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
          "Couldn't Load \(kind.name)", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let notifications) where notifications.isEmpty:
        ContentUnavailableView(
          "No \(kind.name)", systemImage: kind.symbol, description: Text(kind.emptyDescription))
      case .loaded(let notifications):
        List {
          ForEach(
            monthSections(notifications, calendar: calendar, startDate: \.startDate), id: \.month
          ) { section in
            Section(section.month.formatted(.dateTime.month(.wide).year())) {
              ForEach(section.records) { notification in
                NavigationLink {
                  NotificationDetailView(kind: kind, notification: notification)
                } label: {
                  NotificationRow(kind: kind, notification: notification, calendar: calendar)
                }
              }
            }
          }
          if notifications.count >= RecentNotifications.limit {
            Text("Showing the \(RecentNotifications.limit.formatted()) most recent notifications.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .navigationTitle(kind.name)
  }
}

/// A notification in the list: when, and what it said, if the notification says.
struct NotificationRow: View {
  let kind: HealthNotificationKind
  let notification: HealthSample
  var calendar = Calendar.current

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: kind.symbol)
        .font(.title3)
        .foregroundStyle(kind.color)
        .frame(width: 36, height: 36)
        .background(kind.color.opacity(0.15), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(notification.start.formatted(date: .abbreviated, time: .shortened))
          .font(.headline)
        if let summary = HealthDatabase.notificationSummary(notification) {
          Text(summary.line(calendar: calendar))
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
    }
    .padding(.vertical, 4)
  }
}

/// A notification's detail, with the heart rate around it for heart rate notifications.
struct NotificationDetailView: View {
  let kind: HealthNotificationKind
  let notification: HealthSample
  @Dependency(\.defaultDatabase) private var database
  @State private var heartRates: [HealthSample]?

  var body: some View {
    NotificationDetailContent(kind: kind, notification: notification, heartRates: heartRates)
      .task(id: notification.id) {
        guard kind.chartsHeartRate else { return }
        let notification = notification
        let samples = try? await database.read { db in
          try HealthDatabase.samples(
            of: HealthDatabase.heartRateType,
            in: notification
              .start..<max(notification.end, notification.start.addingTimeInterval(1)),
            db)
        }
        heartRates = WorkoutDetailView.mainSource(samples ?? [])
      }
  }
}

/// What a notification's detail shows: when, what it said, the heart rate or beat-to-beat
/// measurements behind it where it has them, where it came from, and its metadata as recorded.
struct NotificationDetailContent: View {
  let kind: HealthNotificationKind
  let notification: HealthSample
  /// Heart rate over the notification's period, for heart rate notifications: nil while loading.
  var heartRates: [HealthSample]?
  var calendar = Calendar.current

  var body: some View {
    let summary = HealthDatabase.notificationSummary(notification)
    Form {
      Section {
        if let summary {
          Text(summary.line(calendar: calendar))
            .font(.title2.weight(.semibold))
            .foregroundStyle(kind.color)
        }
        if notification.endDate > notification.startDate {
          LabeledContent("Start", value: notification.start, format: .dateTime)
          LabeledContent("End", value: notification.end, format: .dateTime)
        } else {
          LabeledContent("Date", value: notification.start, format: .dateTime)
        }
        figures(summary)
      }
      if kind.chartsHeartRate {
        Section("Heart Rate") {
          heartRateChart(threshold: summary)
        }
      }
      if kind == .irregularRhythm {
        Section {
          NavigationLink("Beat-to-Beat Measurements") {
            HeartbeatSeriesView()
          }
        } footer: {
          Text("Apple Watch checks the time between heartbeats for an irregular rhythm.")
        }
      }
      Section("Source") {
        LabeledContent("App", value: notification.sourceName)
        if let device = notification.decodedDevice?.name {
          LabeledContent("Device", value: device)
        }
      }
      let metadata = notification.metadataEntries
      if !metadata.isEmpty {
        Section("Metadata") {
          ForEach(metadata, id: \.key) { entry in
            LabeledContent(SampleFormat.key(entry.key), value: entry.value)
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(kind.name)
  }

  /// The figures the notification recorded, one to a line.
  @ViewBuilder private func figures(_ summary: HealthNotificationSummary?) -> some View {
    switch summary {
    case .cardioFitness(let vo2Max, let threshold):
      if let vo2Max { LabeledContent("VO₂ Max", value: "\(vo2Max.formatted()) mL/kg·min") }
      if let threshold {
        LabeledContent("Threshold", value: "\(threshold.formatted()) mL/kg·min")
      }
    case .soundExposure(let level, let duration):
      if let level { LabeledContent("Level", value: "\(Int(level.rounded())) dB") }
      if let duration {
        LabeledContent("Duration", value: HealthNotificationSummary.duration(duration))
      }
    case .walkingSteadiness(let name):
      LabeledContent("Walking Steadiness", value: name)
    default:
      EmptyView()
    }
  }

  @ViewBuilder private func heartRateChart(threshold summary: HealthNotificationSummary?)
    -> some View
  {
    switch heartRates {
    case nil:
      ProgressView()
        .frame(maxWidth: .infinity, minHeight: 160)
    case let samples? where samples.isEmpty:
      Text("No heart rate readings during this notification.")
        .foregroundStyle(.secondary)
    case let samples?:
      let threshold: Double? =
        switch summary {
        case .heartRateAbove(let value), .heartRateBelow(let value): value
        default: nil
        }
      Chart {
        ForEach(samples) { sample in
          if let value = sample.value {
            LineMark(x: .value("Time", sample.start), y: .value("BPM", value))
              .foregroundStyle(.red)
            PointMark(x: .value("Time", sample.start), y: .value("BPM", value))
              .foregroundStyle(.red)
              .symbolSize(20)
          }
        }
        if let threshold {
          RuleMark(y: .value("Threshold", threshold))
            .foregroundStyle(.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
      }
      .chartYScale(domain: .automatic(includesZero: false))
      .chartXAxis {
        AxisMarks { _ in
          AxisGridLine()
          AxisValueLabel(format: .dateTime.hour().minute())
        }
      }
      .frame(height: 160)
    }
  }
}

extension HealthNotificationKind {
  /// Its name in Health, e.g. "High Heart Rate Notifications".
  var name: String { HealthCatalog.type(id: rawValue)?.name ?? "Notifications" }

  var symbol: String {
    switch self {
    case .highHeartRate, .lowHeartRate: "heart.fill"
    case .irregularRhythm: "waveform.path.ecg"
    case .lowCardioFitness: "figure.run"
    case .hypertension: "heart.text.square.fill"
    case .noise: "ear"
    case .headphone: "headphones"
    case .walkingSteadiness: "figure.walk.motion"
    case .sleepApnea: "lungs.fill"
    }
  }

  var color: Color { HealthCatalog.type(id: rawValue)?.category?.color ?? .red }

  /// Where notifications of the kind come from, for its empty page.
  var emptyDescription: String {
    switch self {
    case .highHeartRate, .lowHeartRate, .irregularRhythm, .lowCardioFitness, .hypertension,
      .sleepApnea, .noise:
      "\(name) from your Apple Watch will appear here."
    case .headphone:
      "\(name) about loud listening on your headphones will appear here."
    case .walkingSteadiness:
      "\(name) from your iPhone will appear here."
    }
  }
}
