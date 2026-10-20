import Foundation
import HealthDatabase
import SQLiteData
import SwiftUI

/// Health Details, as in Health: the profile from the iPhone's characteristics, Not Set for any
/// value that isn't, and the vision prescriptions. Follows the local database as sync changes it.
struct HealthDetailsView: View {
  @Fetch private var characteristics: [HealthCharacteristic]

  init() {
    _characteristics = Fetch(
      wrappedValue: [], HealthCharacteristics(), scheduler: MainQueueScheduler())
  }

  var body: some View {
    HealthDetailsContent(
      state: $characteristics.loadError.map { .failed($0.localizedDescription) }
        ?? ($characteristics.isLoading && characteristics.isEmpty
          ? .loading : .loaded(HealthDetails(characteristics: characteristics))))
  }
}

/// Every synced characteristic.
struct HealthCharacteristics: FetchKeyRequest {
  func fetch(_ db: Database) throws -> [HealthCharacteristic] {
    try HealthDatabase.characteristics(db)
  }
}

/// What Health Details shows, however it got it.
struct HealthDetailsContent: View {
  enum State {
    case loading
    case loaded(HealthDetails)
    case failed(String)
  }

  let state: State
  var now = Date.now
  var calendar = Calendar.current

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load Health Details", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let details):
        page(details)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.pageBackground)
    .navigationTitle("Health Details")
  }

  private func page(_ details: HealthDetails) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Image(systemName: "person.crop.circle.fill")
          .font(.system(size: 64))
          .foregroundStyle(.white, .gray.gradient)
          .frame(maxWidth: .infinity)
          .padding(.bottom, 10)
          .accessibilityHidden(true)

        VStack(spacing: 0) {
          let rows = HealthDetailsFormat.rows(details, now: now, calendar: calendar)
          ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            if index > 0 { Divider().padding(.leading, 14) }
            HStack {
              Text(row.name)
              Spacer()
              Text(row.value)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
          }
        }
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))

        Text(
          details.hasSynced
            ? "Health Details come from Health on your iPhone. Change them there."
            : "Health Details appear here once lil health on your iPhone can read them from Health."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)

        Text("Vision")
          .font(.title3.bold())
          .padding(.top, 14)
        NavigationLink {
          VisionPrescriptionsView()
        } label: {
          HStack {
            Label {
              Text("Vision Prescriptions")
            } icon: {
              Image(systemName: "eyeglasses")
                .foregroundStyle(.blue)
            }
            Spacer()
            Image(systemName: "chevron.right")
              .font(.caption.bold())
              .foregroundStyle(.tertiary)
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
      }
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
  }
}

/// How Health Details read.
enum HealthDetailsFormat {
  struct Row: Equatable {
    let name: String
    let value: String
  }

  static let notSet = "Not Set"

  /// Health's rows, in its order.
  static func rows(
    _ details: HealthDetails, now: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent
  ) -> [Row] {
    [
      Row(
        name: "Date of Birth",
        value: details.dateOfBirth.flatMap {
          dateOfBirth($0, now: now, calendar: calendar, locale: locale)
        } ?? notSet),
      Row(name: "Sex", value: details.sex?.name ?? notSet),
      Row(name: "Blood Type", value: details.bloodType?.name ?? notSet),
      Row(name: "Fitzpatrick Skin Type", value: details.skinType?.name ?? notSet),
      Row(name: "Wheelchair", value: details.wheelchairUse?.name ?? notSet),
    ]
  }

  /// The day, in the user's calendar, with the age it makes them: "Apr 2, 1990 (age 35)".
  static func dateOfBirth(
    _ birth: BirthDate, now: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent
  ) -> String? {
    guard let date = birth.date(in: calendar) else { return nil }
    var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
    style.calendar = calendar
    style.timeZone = calendar.timeZone
    style.locale = locale
    let day = date.formatted(style)
    guard let age = birth.age(at: now, calendar: calendar) else { return day }
    return "\(day) (age \(age))"
  }
}
