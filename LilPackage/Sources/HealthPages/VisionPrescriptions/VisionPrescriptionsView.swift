import Dependencies
import Foundation
import HealthDatabase
import HealthUI
import SQLiteData
public import SwiftUI

/// Glasses and contacts prescriptions, newest first, as in Health. Each opens its lenses. Follows
/// the local database as sync changes it.
public struct VisionPrescriptionsView: View {
  @Fetch private var prescriptions: [HealthVisionPrescription]

  public init() {
    _prescriptions = Fetch(
      wrappedValue: [], RecentVisionPrescriptions(), scheduler: MainQueueScheduler())
  }

  public var body: some View {
    VisionPrescriptionsContent(
      state: $prescriptions.loadError.map { .failed($0.localizedDescription) }
        ?? ($prescriptions.isLoading && prescriptions.isEmpty
          ? .loading : .loaded(prescriptions)))
  }
}

/// The most recent prescriptions: people have a handful.
struct RecentVisionPrescriptions: FetchKeyRequest {
  static let limit = 200

  func fetch(_ db: Database) throws -> [HealthVisionPrescription] {
    try HealthDatabase.visionPrescriptions(limit: Self.limit, db)
  }
}

/// What the prescription list shows, however it got it.
struct VisionPrescriptionsContent: View {
  enum State {
    case loading
    case loaded([HealthVisionPrescription])
    case failed(String)
  }

  let state: State
  /// How many the list holds at most (`RecentVisionPrescriptions.limit`), to say when it's full.
  var limit = RecentVisionPrescriptions.limit
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.date.now) private var now
  @Dependency(\.calendar) private var calendar

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load Vision Prescriptions", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let prescriptions) where prescriptions.isEmpty:
        ContentUnavailableView(
          "No Vision Prescriptions", systemImage: "eyeglasses",
          description: Text(
            "Glasses and contact lens prescriptions you add in Health on your iPhone will appear here."
          ))
      case .loaded(let prescriptions):
        list(prescriptions)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle("Vision Prescriptions")
  }

  /// A grouped form on its own background, as Metric Detail is (851-2989, 851-3004): a
  /// navigation row for each prescription.
  private func list(_ prescriptions: [HealthVisionPrescription]) -> some View {
    // Read once: a dependency's `now` is the time each time it's read.
    let now = now
    let calendar = calendar
    return Form {
      Section {
        ForEach(prescriptions) { prescription in
          NavigationLink {
            VisionPrescriptionDetailView(prescription: prescription)
          } label: {
            VisionPrescriptionRow(prescription: prescription, now: now, calendar: calendar)
          }
        }
      } footer: {
        if prescriptions.count >= limit {
          Text("Showing the \(limit.formatted()) most recent prescriptions.")
        }
      }
    }
    .formStyle(.grouped)
  }
}

/// A prescription in the list: glasses or contacts, when it was issued, and when it expires.
struct VisionPrescriptionRow: View {
  let prescription: HealthVisionPrescription
  let now: Date
  let calendar: Calendar

  var body: some View {
    HStack(spacing: 12) {
      VisionPrescriptionIcon(kind: prescription.kind)
      VStack(alignment: .leading, spacing: 2) {
        Text(VisionFormat.title(prescription))
          .font(.headline)
        Text("Issued \(prescription.issued.formatted(date: .abbreviated, time: .omitted))")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if prescription.isExpired(at: now, calendar: calendar) {
        Text("Expired")
          .foregroundStyle(.orange)
      } else if let expires = prescription.expires {
        Text("Expires \(expires.formatted(date: .abbreviated, time: .omitted))")
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}

/// Glasses or an eye, in a circle.
struct VisionPrescriptionIcon: View {
  let kind: VisionPrescriptionKind?

  var body: some View {
    Image(systemName: kind == .contacts ? "eye" : "eyeglasses")
      .font(.title3)
      .foregroundStyle(.blue)
      .frame(width: 36, height: 36)
      .background(.blue.opacity(0.15), in: Circle())
  }
}

/// A prescription, following the local database as sync changes it: edits show, and one no
/// longer shared says so rather than showing what it was.
struct VisionPrescriptionDetailView: View {
  let opened: HealthVisionPrescription
  /// Read by the view's task, not in its initializer: a list's links make their destinations
  /// as they show, so reading then would touch the database for every row, catalogs included.
  @Fetch private var prescription: HealthVisionPrescription?? = nil

  /// Opens with `prescription` while its row is read.
  init(prescription: HealthVisionPrescription) {
    opened = prescription
  }

  var body: some View {
    // `nil` until read; then the row, or `nil` inside once it's no longer shared.
    VisionPrescriptionDetailContent(prescription: prescription ?? opened)
      .task {
        _ = try? await $prescription.load(
          VisionPrescriptionRequest(id: opened.id), scheduler: MainQueueScheduler())
      }
  }
}

/// A prescription's row, or `nil` once it's no longer shared.
struct VisionPrescriptionRequest: FetchKeyRequest {
  let id: String

  func fetch(_ db: Database) throws -> HealthVisionPrescription?? {
    .some(try HealthDatabase.visionPrescription(id: id, db))
  }
}

/// A prescription, as in Health: what it's for, when it was issued and expires, and each eye's
/// lens side by side, right (OD) then left (OS), as prescriptions are written. `nil` once it's
/// no longer shared.
struct VisionPrescriptionDetailContent: View {
  let prescription: HealthVisionPrescription?
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.date.now) private var now
  @Dependency(\.calendar) private var calendar

  var body: some View {
    Group {
      if let prescription {
        page(prescription)
      } else {
        ContentUnavailableView(
          "No Longer Shared", systemImage: "eyeglasses",
          description: Text("This prescription was deleted or is no longer shared with lil health.")
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle(prescription?.kindName ?? "Vision Prescription")
  }

  /// A grouped form on its own background, as Metric Detail is (851-2989, 851-3004): what it's
  /// for and its dates, the lenses, then its source.
  private func page(_ prescription: HealthVisionPrescription) -> some View {
    Form {
      summary(prescription)
      Section("Prescription") {
        lenses(prescription)
      }
      Section {
        LabeledContent("Source", value: prescription.sourceName)
      }
    }
    .formStyle(.grouped)
  }

  private func summary(_ prescription: HealthVisionPrescription) -> some View {
    Section {
      HStack(spacing: 12) {
        VisionPrescriptionIcon(kind: prescription.kind)
        VStack(alignment: .leading, spacing: 2) {
          Text(prescription.kindName)
            .font(.title2.bold())
          if let brand = prescription.brand, !brand.isEmpty {
            Text(brand)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
      }
      .padding(.vertical, 4)
      LabeledContent(
        "Date Issued", value: prescription.issued.formatted(date: .long, time: .omitted))
      if let expires = prescription.expires {
        LabeledContent("Expiration Date") {
          HStack {
            if prescription.isExpired(at: now, calendar: calendar) {
              Text("Expired")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange, in: Capsule())
            }
            Text(expires.formatted(date: .long, time: .omitted))
          }
        }
      }
    }
  }

  private func lenses(_ prescription: HealthVisionPrescription) -> some View {
    let rows = VisionFormat.rows(
      right: prescription.decodedRightEye, left: prescription.decodedLeftEye)
    return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
      GridRow {
        Color.clear
          .gridCellUnsizedAxes([.horizontal, .vertical])
        Text("Right (OD)")
          .padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("Left (OS)")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      ForEach(rows, id: \.name) { row in
        Divider()
        GridRow {
          Text(row.name)
            .padding(.vertical, 10)
          Text(row.right)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(row.left)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
}

/// How prescriptions read, as they're written: diopters signed with two decimals, the axis in
/// degrees, distances in millimeters and prisms in prism diopters toward their base.
enum VisionFormat {
  /// A row of the lens table: a value and each eye's, "–" for an eye without it.
  struct Row: Equatable {
    let name: String
    let right: String
    let left: String
  }

  static let missing = "–"

  /// The list's title: "Glasses", or contacts with their brand.
  static func title(_ prescription: HealthVisionPrescription) -> String {
    guard let brand = prescription.brand, !brand.isEmpty else { return prescription.kindName }
    return "\(prescription.kindName) · \(brand)"
  }

  /// Sphere, cylinder, axis and add, then glasses' prism, vertex and pupillary distances or
  /// contacts' base curve and diameter. Sphere always; the others when either eye has them.
  static func rows(
    right: VisionLens?, left: VisionLens?, locale: Locale = .autoupdatingCurrent
  ) -> [Row] {
    let values: [(name: String, value: (VisionLens) -> String?, always: Bool)] = [
      ("Sphere", { $0.sphere.map { diopters($0, locale: locale) } }, true),
      ("Cylinder", { $0.cylinder.map { diopters($0, locale: locale) } }, false),
      ("Axis", { $0.axis.map { degrees($0, locale: locale) } }, false),
      ("Add", { $0.addPower.map { diopters($0, locale: locale) } }, false),
      ("Prism", { $0.prism.flatMap { prism($0, locale: locale) } }, false),
      (
        "Vertex Distance", { $0.vertexDistance.map { millimeters($0, locale: locale) } },
        false
      ),
      ("Far PD", { $0.farPupillaryDistance.map { millimeters($0, locale: locale) } }, false),
      ("Near PD", { $0.nearPupillaryDistance.map { millimeters($0, locale: locale) } }, false),
      ("Base Curve", { $0.baseCurve.map { millimeters($0, locale: locale) } }, false),
      ("Diameter", { $0.diameter.map { millimeters($0, locale: locale) } }, false),
    ]
    return values.compactMap { name, value, always in
      let (rightValue, leftValue) = (right.flatMap(value), left.flatMap(value))
      guard always || rightValue != nil || leftValue != nil else { return nil }
      return Row(name: name, right: rightValue ?? missing, left: leftValue ?? missing)
    }
  }

  /// "+1.25", "−2.00" or "0.00".
  static func diopters(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
    let rounded = (value * 100).rounded() / 100
    let magnitude = abs(rounded).formatted(
      .number.precision(.fractionLength(2)).grouping(.never).locale(locale))
    return rounded > 0 ? "+\(magnitude)" : rounded < 0 ? "−\(magnitude)" : magnitude
  }

  /// "90°".
  static func degrees(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
    "\(value.formatted(.number.precision(.fractionLength(0)).locale(locale)))°"
  }

  /// "12 mm" or "31.5 mm".
  static func millimeters(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
    "\(value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))) mm"
  }

  /// Its vertical and horizontal parts toward their bases, "1 Δ Base Up, 0.5 Δ Base In", or its
  /// amount at its angle, "2 Δ at 45°", for one given only that way or with a part whose base
  /// can't be read (rather than showing part of it). `nil` without either.
  static func prism(_ prism: VisionPrism, locale: Locale = .autoupdatingCurrent) -> String? {
    func amount(_ value: Double) -> String {
      "\(value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))) Δ"
    }
    let parts = [
      (prism.verticalAmount, prism.verticalBase), (prism.horizontalAmount, prism.horizontalBase),
    ]
    .compactMap { value, base -> String?? in
      guard let value, value != 0 else { return nil }
      // A part without a base we know: unreadable, so the whole prism falls back.
      return .some(base.map { "\(amount(value)) Base \($0.name)" })
    }
    if !parts.isEmpty, parts.allSatisfy({ $0 != nil }) {
      return parts.compactMap { $0 }.joined(separator: ", ")
    }
    guard let value = prism.amount, value != 0 else { return nil }
    guard let angle = prism.angle else { return amount(value) }
    return "\(amount(value)) at \(degrees(angle, locale: locale))"
  }
}
