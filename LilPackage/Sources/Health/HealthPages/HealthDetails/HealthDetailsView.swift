import Foundation
import HealthDatabase
import HealthUI
import SQLiteData
public import SwiftUI

/// Health Details, as in Health: the profile from the iPhone's characteristics, Not Set for any
/// value that isn't, and the vision prescriptions. Follows the local database as sync changes it.
/// Vision Prescriptions is a value link, to its type ID, so the stack showing Health Details needs
/// a destination for one (`navigationDestination(for: String.self)`).
public struct HealthDetailsView: View {
  @Fetch private var characteristics: [HealthCharacteristic]

  public init() {
    _characteristics = Fetch(
      wrappedValue: [], HealthCharacteristics(), scheduler: MainQueueScheduler())
  }

  public var body: some View {
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
  /// For ages. From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.date.now) private var now
  @Dependency(\.calendar) private var calendar

  var body: some View {
    Group {
      switch state {
      // The page's rows, without values yet, so nothing moves when they load (851-3092).
      case .loading:
        form(nil)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load Health Details", systemImage: "exclamationmark.triangle",
          description: Text(reason)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded(let details):
        form(details)
      }
    }
    .navigationTitle("Health Details")
  }

  /// A grouped form, as Data Sources is (851-3005): the profile under its picture, then Vision.
  /// Without values while they load.
  private func form(_ details: HealthDetails?) -> some View {
    let rows = HealthDetailsFormat.rows(
      details ?? HealthDetails(characteristics: []), now: now, calendar: calendar)
    return Form {
      Section {
        ForEach(rows, id: \.name) { row in
          if details == nil {
            LabeledContent(row.name) {
              Text("–")
                .accessibilityHidden(true)
            }
          } else {
            LabeledContent(row.name, value: row.value)
          }
        }
      } header: {
        Image(systemName: "person.crop.circle.fill")
          .font(.system(size: 64))
          .foregroundStyle(.white, .gray.gradient)
          .frame(maxWidth: .infinity)
          .padding(.bottom, 10)
          .accessibilityHidden(true)
      } footer: {
        Text(
          details?.hasSynced ?? true
            ? "Health Details come from Health on your iPhone. Change them there."
            : "Health Details appear here once lil health on your iPhone can read them from Health."
        )
      }
      Section("Vision") {
        // A value, so the stack's path holds it and opening Health Details pops it (851-3030):
        // the stack's destination for a type ID shows Vision Prescriptions.
        NavigationLink(value: HealthDatabase.visionPrescriptionType) {
          Label {
            Text("Vision Prescriptions")
          } icon: {
            Image(systemName: "eyeglasses")
              .foregroundStyle(.blue)
          }
        }
        .layoutAnchor("Vision")
      }
    }
    .formStyle(.grouped)
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
