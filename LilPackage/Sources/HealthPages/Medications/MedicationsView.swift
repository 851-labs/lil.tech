import Dependencies
import Foundation
import HealthCatalog
import HealthDatabase
import HealthUI
import SQLiteData
public import SwiftUI

/// The medications the person shares, current ones then archived ones, each with its schedule.
/// Each opens its adherence and dose log. Follows the local database as sync changes it.
public struct MedicationsView: View {
  @Fetch private var medications: [HealthMedication]

  public init() {
    _medications = Fetch(wrappedValue: [], AllMedications(), scheduler: MainQueueScheduler())
  }

  public var body: some View {
    MedicationsContent(
      state: $medications.loadError.map { .failed($0.localizedDescription) }
        ?? ($medications.isLoading && medications.isEmpty ? .loading : .loaded(medications)))
  }
}

/// Every shared medication: people have a handful.
struct AllMedications: FetchKeyRequest {
  func fetch(_ db: Database) throws -> [HealthMedication] {
    try HealthDatabase.medications(db)
  }
}

/// What the medication list shows, however it got it.
struct MedicationsContent: View {
  enum State {
    case loading
    case loaded([HealthMedication])
    case failed(String)
  }

  let state: State

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load Medications", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let medications) where medications.isEmpty:
        ContentUnavailableView(
          "No Medications", systemImage: "pills",
          description: Text(
            "Medications you share with lil health on your iPhone will appear here, with the doses you log in Health."
          ))
      case .loaded(let medications):
        list(medications)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle("Medications")
  }

  /// A grouped form on its own background, as Metric Detail is (851-2989, 851-3004): current
  /// medications, then archived ones, a navigation row each.
  private func list(_ medications: [HealthMedication]) -> some View {
    let current = medications.filter { !$0.isArchived }
    let archived = medications.filter(\.isArchived)
    return Form {
      if !current.isEmpty {
        section("Your Medications", current)
      }
      if !archived.isEmpty {
        section("Archived Medications", archived)
      }
    }
    .formStyle(.grouped)
  }

  private func section(_ title: String, _ medications: [HealthMedication]) -> some View {
    Section(title) {
      ForEach(medications) { medication in
        NavigationLink {
          MedicationDetailView(medication: medication)
        } label: {
          MedicationRow(medication: medication)
        }
      }
    }
  }
}

/// A medication in the list: its name, Health's name and form, and whether it's scheduled.
struct MedicationRow: View {
  let medication: HealthMedication

  var body: some View {
    HStack(spacing: 12) {
      MedicationIcon(medication: medication)
      VStack(alignment: .leading, spacing: 2) {
        Text(medication.displayName)
          .font(.headline)
        if let details = MedicationFormat.details(medication) {
          Text(details)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Text(MedicationFormat.schedule(medication))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

/// The medication's form, in a circle in Health's color for medications.
struct MedicationIcon: View {
  let medication: HealthMedication

  var body: some View {
    Image(systemName: MedicationFormat.symbol(medication))
      .font(.title3)
      .foregroundStyle(HealthCategory.medications.color)
      .frame(width: 36, height: 36)
      .background(HealthCategory.medications.color.opacity(0.15), in: Circle())
      .accessibilityHidden(true)
  }
}

/// A medication, following the local database as sync changes it: new doses show, and one no
/// longer shared says so rather than showing what it was.
struct MedicationDetailView: View {
  let opened: HealthMedication
  /// Moves at midnight, so the windows and Today do even if nothing syncs.
  @State private var today = Date.now
  @Dependency(\.calendar) private var calendar
  /// Read by the view's task, not in its initializer: a list's links make their destinations as
  /// they show, so reading then would touch the database for every row, catalogs included.
  @Fetch private var detail: MedicationDetail?? = nil

  /// Opens with `medication` while its doses are read.
  init(medication: HealthMedication) {
    opened = medication
  }

  var body: some View {
    MedicationDetailContent(
      state: $detail.loadError.map { .failed($0.localizedDescription) }
        // `nil` until read; then the detail, or `nil` inside once it's no longer shared.
        ?? detail.map { $0.map { .loaded($0) } ?? .noLongerShared } ?? .loading(opened),
      now: today
    )
    .task(id: today) {
      _ = try? await $detail.load(
        MedicationDetailRequest(id: opened.id, now: today, calendar: calendar),
        scheduler: MainQueueScheduler())
    }
    .onReceive(calendarDayChanges()) {
      today = .now
    }
  }
}

/// A medication's detail, or `nil` once it's no longer shared.
struct MedicationDetailRequest: FetchKeyRequest {
  /// How many doses the log shows at most: a year of three a day.
  static let limit = 1_000

  let id: String
  let now: Date
  let calendar: Calendar

  func fetch(_ db: Database) throws -> MedicationDetail?? {
    .some(
      try HealthDatabase.medicationDetail(
        id: id, now: now, calendar: calendar, limit: Self.limit, db))
  }
}

/// A medication: its names and schedule, how many scheduled doses were taken over the last 7 and
/// 30 days, and its doses by day, newest first.
struct MedicationDetailContent: View {
  enum State {
    /// The medication from the list, while its doses are read.
    case loading(HealthMedication)
    case loaded(MedicationDetail)
    case noLongerShared
    case failed(String)
  }

  let state: State
  let limit: Int
  /// How many doses the log shows at first, and how many more each Show More Doses adds. A grouped
  /// form lays out every row, not only those on screen, so a year of doses at once would take
  /// seconds to open (851-3004).
  let pageSize: Int
  /// Today, which moves at midnight (`MedicationDetailView`).
  let now: Date
  /// From dependencies, so snapshot catalogs fix it (`previewCalendar`).
  @Dependency(\.calendar) private var calendar
  /// How many doses the log shows: `pageSize`, and `pageSize` more each time Show More Doses is clicked.
  @SwiftUI.State private var shownDoses: Int

  init(state: State, limit: Int = MedicationDetailRequest.limit, pageSize: Int = 100, now: Date) {
    self.state = state
    self.limit = limit
    self.pageSize = pageSize
    self.now = now
    _shownDoses = SwiftUI.State(initialValue: pageSize)
  }

  var body: some View {
    Group {
      switch state {
      case .loading(let medication):
        page(medication) {
          Section {
            ProgressView()
              .frame(maxWidth: .infinity, minHeight: 200)
          }
        }
      case .loaded(let detail):
        page(detail.medication) {
          adherence(detail)
          log(detail)
        }
      case .noLongerShared:
        ContentUnavailableView(
          "No Longer Shared", systemImage: "pills",
          description: Text("This medication was deleted or is no longer shared with lil health."))
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load Medication", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle(medication?.displayName ?? "Medication")
  }

  private var medication: HealthMedication? {
    switch state {
    case .loading(let medication): medication
    case .loaded(let detail): detail.medication
    case .noLongerShared, .failed: nil
    }
  }

  /// A grouped form on its own background, as Metric Detail is (851-2989, 851-3004): the
  /// medication, its adherence, then its log, a section a day.
  private func page(
    _ medication: HealthMedication, @ViewBuilder content: () -> some View
  ) -> some View {
    Form {
      summary(medication)
      content()
    }
    .formStyle(.grouped)
  }

  private func summary(_ medication: HealthMedication) -> some View {
    Section {
      HStack(spacing: 12) {
        MedicationIcon(medication: medication)
        VStack(alignment: .leading, spacing: 2) {
          Text(medication.displayName)
            .font(.title2.bold())
          if let details = MedicationFormat.details(medication) {
            Text(details)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        if medication.isArchived {
          Text("Archived")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.gray, in: Capsule())
        }
      }
      .padding(.vertical, 4)
      LabeledContent("Schedule", value: MedicationFormat.schedule(medication))
    }
  }

  private func adherence(_ detail: MedicationDetail) -> some View {
    Section {
      HStack(alignment: .top, spacing: 14) {
        ForEach(Array(detail.adherence.enumerated()), id: \.offset) { index, adherence in
          if index > 0 { Divider() }
          AdherenceColumn(adherence: adherence)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, 6)
    } header: {
      // Only scheduled doses have an adherence; as-needed ones are only counted.
      Text(
        detail.medication.hasSchedule || detail.adherence.contains { $0.scheduled > 0 }
          ? "Adherence" : "Doses Taken")
    }
  }

  /// The log: a section a day, headed by the day, or a note before any dose is logged.
  @ViewBuilder
  private func log(_ detail: MedicationDetail) -> some View {
    if detail.days.isEmpty {
      Section("Log") {
        Text("No doses logged yet. Doses you log in Health on your iPhone will appear here.")
          .foregroundStyle(.secondary)
      }
    }
    let days = MedicationFormat.days(detail.days, upTo: shownDoses)
    ForEach(days) { day in
      Section {
        ForEach(day.doses) { dose in
          MedicationDoseRow(dose: dose, medication: detail.medication, calendar: calendar)
        }
      } header: {
        Text(MedicationFormat.day(day.day, now: now, calendar: calendar))
      } footer: {
        if detail.isLimited, day.id == detail.days.last?.id {
          Text("Showing the \(limit.formatted()) most recent doses.")
        }
      }
    }
    if days.count < detail.days.count {
      Section {
        Button("Show More Doses") {
          shownDoses += pageSize
        }
      }
    }
  }
}

/// A window's adherence: the share of scheduled doses taken, and the counts behind it.
struct AdherenceColumn: View {
  let adherence: MedicationAdherence

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Last \(adherence.days) Days")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text(MedicationFormat.adherenceValue(adherence))
        .font(.title.bold())
        .monospacedDigit()
      if let fraction = adherence.fraction {
        // Drawn, not a `ProgressView`, which turns gray whenever its window isn't key.
        Capsule()
          .fill(.quaternary)
          .frame(height: 6)
          .overlay(alignment: .leading) {
            GeometryReader { proxy in
              Capsule()
                .fill(HealthCategory.medications.color)
                .frame(width: proxy.size.width * fraction)
            }
          }
          .accessibilityHidden(true)
      }
      Text(MedicationFormat.adherenceCaption(adherence))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A dose in the log: what happened, when, and how much.
struct MedicationDoseRow: View {
  let dose: HealthMedicationDose
  let medication: HealthMedication
  let calendar: Calendar

  var body: some View {
    HStack(spacing: 12) {
      MedicationStatusIcon(status: dose.status)
      VStack(alignment: .leading, spacing: 2) {
        Text(dose.status?.name ?? "Logged")
        Text(MedicationFormat.times(dose, calendar: calendar))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let quantity = MedicationFormat.quantity(dose, medication: medication) {
        Text(quantity)
          .monospacedDigit()
          .foregroundStyle(dose.status == .taken ? .primary : .secondary)
      }
    }
    .padding(.vertical, 2)
  }
}

/// A dose's status: a check for taken, a cross for skipped, a clock for snoozed, a dashed circle
/// for not logged.
struct MedicationStatusIcon: View {
  let status: MedicationDoseStatus?

  var body: some View {
    let (symbol, color): (String, Color) =
      switch status {
      case .taken: ("checkmark.circle.fill", HealthCategory.medications.color)
      case .skipped: ("xmark.circle.fill", .secondary)
      case .snoozed: ("clock.fill", .orange)
      case .notificationNotSent: ("bell.slash.fill", .secondary)
      case .notInteracted, .notLogged: ("circle.dashed", .secondary)
      case nil: ("circle", .secondary)
      }
    Image(systemName: symbol)
      .font(.title3)
      .foregroundStyle(color)
      .frame(width: 20)
      .accessibilityHidden(true)
  }
}

/// How medications and their doses read.
enum MedicationFormat {
  /// Health's name, when a nickname replaces it, and the form: "Synthetic Tablet A · Tablet".
  /// `nil` without either.
  static func details(_ medication: HealthMedication) -> String? {
    let parts = [
      medication.displayName == medication.name ? nil : medication.name, medication.formName,
    ]
    .compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// The log's newest days, whole, until they hold `doses` doses (at least one day).
  static func days(_ days: [MedicationDoseDay], upTo doses: Int) -> [MedicationDoseDay] {
    var shown = 0
    var count = 0
    for day in days {
      guard shown < doses else { break }
      shown += day.doses.count
      count += 1
    }
    return Array(days.prefix(count))
  }

  /// "Scheduled" or "As Needed".
  static func schedule(_ medication: HealthMedication) -> String {
    medication.hasSchedule ? "Scheduled" : "As Needed"
  }

  /// A symbol for the medication's form.
  static func symbol(_ medication: HealthMedication) -> String {
    switch medication.generalForm {
    case "capsule": "capsule.fill"
    case "drops", "liquid": "drop.fill"
    case "injection": "syringe.fill"
    case "patch": "bandage.fill"
    case "cream", "gel", "lotion", "ointment", "topical", "foam": "hand.raised.fill"
    default: "pills.fill"
    }
  }

  /// The share of scheduled doses taken, "86%"; the doses taken as needed when nothing was
  /// scheduled, "3"; or "–" for neither.
  static func adherenceValue(
    _ adherence: MedicationAdherence, locale: Locale = .autoupdatingCurrent
  ) -> String {
    if let fraction = adherence.fraction {
      return fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
    return adherence.takenAsNeeded > 0 ? adherence.takenAsNeeded.formatted() : "–"
  }

  /// What the value counts: "6 of 7 scheduled doses taken", with any taken as needed besides.
  static func adherenceCaption(_ adherence: MedicationAdherence) -> String {
    let asNeeded = adherence.takenAsNeeded
    guard adherence.scheduled > 0 else {
      return asNeeded == 0
        ? "No doses logged" : asNeeded == 1 ? "Dose taken as needed" : "Doses taken as needed"
    }
    let scheduled =
      "\(adherence.taken) of \(adherence.scheduled) scheduled \(adherence.scheduled == 1 ? "dose" : "doses") taken"
    return asNeeded == 0 ? scheduled : "\(scheduled), plus \(asNeeded) as needed"
  }

  /// A log day's heading: "Today", "Yesterday", or the date, with its year if it isn't this one.
  static func day(
    _ day: Date, now: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent
  ) -> String {
    let today = calendar.startOfDay(for: now)
    if calendar.isDate(day, inSameDayAs: today) { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
      calendar.isDate(day, inSameDayAs: yesterday)
    {
      return "Yesterday"
    }
    var style = Date.FormatStyle(date: .omitted, time: .omitted).weekday(.wide).month(.wide).day()
    if calendar.component(.year, from: day) != calendar.component(.year, from: now) {
      style = style.year()
    }
    style.calendar = calendar
    style.timeZone = calendar.timeZone
    style.locale = locale
    return day.formatted(style)
  }

  /// When a dose was logged, and whether it was scheduled, with the time it was due if that's
  /// another minute: "8:12 AM · Scheduled for 8:00 AM", or "8:00 AM · Scheduled". A scheduled
  /// dose nobody logged only says when it was due.
  static func times(
    _ dose: HealthMedicationDose, calendar: Calendar, locale: Locale = .autoupdatingCurrent
  ) -> String {
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.calendar = calendar
    style.timeZone = calendar.timeZone
    style.locale = locale
    let logged = dose.logged.formatted(style)
    guard let scheduled = dose.scheduled?.formatted(style) else { return logged }
    switch dose.status {
    case .taken, .skipped, .snoozed:
      return logged == scheduled
        ? "\(logged) · Scheduled" : "\(logged) · Scheduled for \(scheduled)"
    default:
      return "Scheduled for \(scheduled)"
    }
  }

  /// How much was taken, or was due for a dose that wasn't taken: "1 tablet", "2 sprays" or
  /// "5 mL". `nil` without either.
  static func quantity(
    _ dose: HealthMedicationDose, medication: HealthMedication,
    locale: Locale = .autoupdatingCurrent
  ) -> String? {
    guard let value = dose.status == .taken ? dose.doseQuantity : dose.scheduledDoseQuantity
    else { return nil }
    let number = value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
    guard dose.unit == "count" else { return "\(number) \(dose.unit)" }
    let (one, many) =
      switch medication.generalForm {
      case "capsule": ("capsule", "capsules")
      case "tablet": ("tablet", "tablets")
      case "drops": ("drop", "drops")
      case "injection": ("injection", "injections")
      case "patch": ("patch", "patches")
      case "spray": ("spray", "sprays")
      case "suppository": ("suppository", "suppositories")
      case "inhaler": ("puff", "puffs")
      default: ("dose", "doses")
      }
    // As shown: 1.0001 is "1 tablet".
    return "\(number) \((value * 100).rounded() == 100 ? one : many)"
  }
}
