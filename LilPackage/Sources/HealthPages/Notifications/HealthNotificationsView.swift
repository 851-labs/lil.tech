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
  @Fetch private var notifications: [HealthNotification]

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

  func fetch(_ db: Database) throws -> [HealthNotification] {
    try HealthDatabase.notifications(of: kind, limit: Self.limit, db)
  }
}

/// What a kind's notifications show, however it got them.
struct HealthNotificationsContent: View {
  enum State {
    case loading
    /// Newest first by the date each is listed under (`HealthNotificationKind.listedDate`).
    case loaded([HealthNotification])
    case failed(String)
  }

  let kind: HealthNotificationKind
  let state: State
  /// How many the list holds at most (`RecentNotifications.limit`), to say when it's full.
  var limit = RecentNotifications.limit
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
          "Couldn't Load \(kind.name)", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let notifications) where notifications.isEmpty:
        ContentUnavailableView(
          "No \(kind.name)", systemImage: kind.symbol, description: Text(kind.emptyDescription))
      case .loaded(let notifications):
        list(notifications)
      }
    }
    .navigationTitle(kind.name)
  }

  /// A section per month, in a grouped form's look (`LazyForm`): a `Form` builds every row at
  /// once, and the list holds up to 1,000.
  private func list(_ notifications: [HealthNotification]) -> some View {
    let months = monthSections(
      notifications, calendar: calendar,
      startDate: { kind.listedDate(of: $0.sample).unixMilliseconds })
    return LazyForm {
      ForEach(months, id: \.month) { section in
        LazyFormHeader(
          title: section.month.formatted(NotificationFormat.month(calendar)),
          isFirst: section.month == months.first?.month)
        ForEach(section.records) { notification in
          NavigationLink {
            NotificationDetailView(kind: kind, notification: notification)
          } label: {
            LazyFormRow(
              isFirst: notification.id == section.records.first?.id,
              isLast: notification.id == section.records.last?.id
            ) {
              NotificationRow(kind: kind, notification: notification, calendar: calendar)
            }
          }
          .buttonStyle(.plain)
        }
      }
      if notifications.count >= limit {
        LazyFormFooter("Showing the \(limit.formatted()) most recent notifications.")
      }
    }
  }
}

/// A notification in the list: when, and what it said, if the notification says.
struct NotificationRow: View {
  let kind: HealthNotificationKind
  let notification: HealthNotification
  let calendar: Calendar

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: kind.symbol)
        .font(.title3)
        .foregroundStyle(kind.color)
        .frame(width: 36, height: 36)
        .background(kind.color.opacity(0.15), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(kind.listedDate(of: notification.sample).formatted(NotificationFormat.date(calendar)))
          .font(.headline)
        if let summary = notification.summary {
          Text(summary.line(calendar: calendar))
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
    }
    .padding(.vertical, 4)
  }
}

/// How notifications' dates read, in the page's calendar (its time zone and locale).
enum NotificationFormat {
  /// "October 2025", a section's.
  static func month(_ calendar: Calendar) -> Date.FormatStyle {
    style(calendar).month(.wide).year()
  }

  /// "Oct 14, 2025 at 9:41 AM".
  static func date(_ calendar: Calendar) -> Date.FormatStyle {
    Date.FormatStyle(
      date: .abbreviated, time: .shortened, locale: calendar.locale ?? .current,
      calendar: calendar, timeZone: calendar.timeZone)
  }

  /// "9:41 AM", a chart's.
  static func time(_ calendar: Calendar) -> Date.FormatStyle {
    style(calendar).hour().minute()
  }

  private static func style(_ calendar: Calendar) -> Date.FormatStyle {
    Date.FormatStyle(
      locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
  }
}

/// A notification's detail, with the heart rate around it for heart rate notifications.
struct NotificationDetailView: View {
  let kind: HealthNotificationKind
  let notification: HealthNotification
  @Dependency(\.defaultDatabase) private var database
  @State private var heartRates = NotificationDetailContent.HeartRates.loading

  var body: some View {
    NotificationDetailContent(kind: kind, notification: notification, heartRates: heartRates)
      .task(id: notification.id) {
        guard kind.chartsHeartRate else { return }
        let window = NotificationDetailContent.heartRateWindow(notification.sample)
        do {
          let samples = try await database.read { db in
            try HealthDatabase.samples(
              of: HealthDatabase.heartRateType, in: window.start..<window.end, db)
          }
          heartRates = .loaded(WorkoutDetailView.mainSource(samples))
        } catch {
          heartRates = .failed(error.localizedDescription)
        }
      }
  }
}

/// What a notification's detail shows: when, what it said, the heart rate or beat-to-beat
/// measurements behind it where it has them, where it came from, and its metadata as recorded.
struct NotificationDetailContent: View {
  /// Heart rate around a heart rate notification.
  enum HeartRates {
    case loading
    case loaded([HealthSample])
    case failed(String)
  }

  let kind: HealthNotificationKind
  let notification: HealthNotification
  var heartRates: HeartRates = .loading
  /// From dependencies, so snapshot catalogs fix it (`previewCalendar`).
  @Dependency(\.calendar) private var calendar
  /// Parsed once, not on every render.
  private let metadata: [(key: String, value: String)]

  init(
    kind: HealthNotificationKind, notification: HealthNotification,
    heartRates: HeartRates = .loading
  ) {
    self.kind = kind
    self.notification = notification
    self.heartRates = heartRates
    metadata = notification.sample.metadataEntries
  }

  /// How long before and after a heart rate notification its chart reaches, so a short (or
  /// instant) one shows the readings around it.
  nonisolated static let heartRatePadding: TimeInterval = 10 * 60

  /// The time a heart rate notification's chart covers: its span, padded either side.
  nonisolated static func heartRateWindow(_ sample: HealthSample) -> DateInterval {
    DateInterval(
      start: sample.start.addingTimeInterval(-heartRatePadding),
      end: max(sample.end, sample.start).addingTimeInterval(heartRatePadding))
  }

  private var sample: HealthSample { notification.sample }

  var body: some View {
    let summary = notification.summary
    let dateStyle = NotificationFormat.date(calendar)
    Form {
      Section {
        if let summary {
          Text(summary.line(calendar: calendar))
            .font(.title2.weight(.semibold))
            .foregroundStyle(kind.color)
        }
        if sample.endDate > sample.startDate {
          LabeledContent("Start", value: sample.start.formatted(dateStyle))
          LabeledContent("End", value: sample.end.formatted(dateStyle))
        } else {
          LabeledContent("Date", value: sample.start.formatted(dateStyle))
        }
        figures(summary)
      }
      if kind.chartsHeartRate {
        Section {
          heartRateChart(summary)
        } header: {
          Text("Heart Rate")
        } footer: {
          if case .loaded(let samples) = heartRates, !samples.isEmpty {
            Text(
              "The shaded band is the notification's time. The chart shows 10 minutes either side.")
          }
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
        LabeledContent("App", value: sample.sourceName)
        if let device = sample.decodedDevice?.name {
          LabeledContent("Device", value: device)
        }
      }
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
    let locale = calendar.locale ?? .current
    switch summary {
    case .cardioFitness(let vo2Max, let threshold):
      vo2MaxFigure("VO₂ Max", vo2Max)
      if let threshold { vo2MaxFigure("Threshold", threshold) }
    case .cardioFitnessThreshold(let threshold):
      vo2MaxFigure("Threshold", threshold)
    case .soundExposure(let level, let duration):
      LabeledContent(
        "Level", value: "\(HealthNotificationSummary.whole(level, locale: locale)) dB")
      if let duration { durationFigure(duration) }
    case .soundDuration(let duration):
      durationFigure(duration)
    case .walkingSteadiness(let name):
      LabeledContent("Walking Steadiness", value: name)
    default:
      EmptyView()
    }
  }

  private func vo2MaxFigure(_ title: String, _ value: Double) -> some View {
    LabeledContent(
      title,
      value:
        "\(HealthNotificationSummary.number(value, locale: calendar.locale ?? .current)) mL/kg·min"
    )
  }

  private func durationFigure(_ seconds: TimeInterval) -> some View {
    LabeledContent(
      "Duration",
      value: HealthNotificationSummary.duration(seconds, locale: calendar.locale ?? .current))
  }

  @ViewBuilder private func heartRateChart(_ summary: HealthNotificationSummary?) -> some View {
    switch heartRates {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, minHeight: 160)
    case .failed(let reason):
      Label("Couldn't load heart rate: \(reason)", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
    case .loaded(let samples) where samples.isEmpty:
      Text("No heart rate readings around this notification.")
        .foregroundStyle(.secondary)
    case .loaded(let samples):
      let threshold: Double? =
        switch summary {
        case .heartRateAbove(let value), .heartRateBelow(let value): value
        default: nil
        }
      let window = Self.heartRateWindow(sample)
      Chart {
        // The notification's own span, or a line at its moment if it has none.
        if sample.endDate > sample.startDate {
          RectangleMark(
            xStart: .value("Start", sample.start), xEnd: .value("End", sample.end)
          )
          .foregroundStyle(kind.color.opacity(0.12))
        } else {
          RuleMark(x: .value("Notification", sample.start))
            .foregroundStyle(kind.color.opacity(0.4))
        }
        ForEach(samples) { reading in
          if let value = reading.value {
            LineMark(x: .value("Time", reading.start), y: .value("BPM", value))
              .foregroundStyle(.red)
            PointMark(x: .value("Time", reading.start), y: .value("BPM", value))
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
      .chartXScale(domain: window.start...window.end)
      .chartYScale(domain: .automatic(includesZero: false))
      .chartXAxis {
        AxisMarks { _ in
          AxisGridLine()
          AxisValueLabel(format: NotificationFormat.time(calendar))
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

  var color: Color { HealthCatalog.type(id: rawValue)?.color ?? HealthDataType.uncategorizedColor }

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
