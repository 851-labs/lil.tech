import Foundation
import HealthDatabase
import SQLiteData
import SwiftUI

/// Glasses and contacts prescriptions, newest first, as in Health. Each opens its lenses. Follows
/// the local database as sync changes it.
struct VisionPrescriptionsView: View {
  @Fetch private var prescriptions: [HealthVisionPrescription]

  init() {
    _prescriptions = Fetch(
      wrappedValue: [], RecentVisionPrescriptions(), scheduler: MainQueueScheduler())
  }

  var body: some View {
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
  var now = Date.now

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
    .background(Color.pageBackground)
    .navigationTitle("Vision Prescriptions")
  }

  private func list(_ prescriptions: [HealthVisionPrescription]) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        VStack(spacing: 0) {
          ForEach(Array(prescriptions.enumerated()), id: \.element.id) { index, prescription in
            if index > 0 { Divider().padding(.leading, 62) }
            NavigationLink {
              VisionPrescriptionDetailView(prescription: prescription, now: now)
            } label: {
              VisionPrescriptionRow(prescription: prescription, now: now)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        if prescriptions.count >= limit {
          Text("Showing the \(limit.formatted()) most recent prescriptions.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
        }
      }
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
  }
}

/// A prescription in the list: glasses or contacts, when it was issued, and when it expires.
struct VisionPrescriptionRow: View {
  let prescription: HealthVisionPrescription
  let now: Date

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
      if prescription.isExpired(at: now) {
        Text("Expired")
          .foregroundStyle(.orange)
      } else if let expires = prescription.expires {
        Text("Expires \(expires.formatted(date: .abbreviated, time: .omitted))")
          .foregroundStyle(.secondary)
      }
      Image(systemName: "chevron.right")
        .font(.caption.bold())
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
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

/// A prescription, as in Health: what it's for, when it was issued and expires, and each eye's
/// lens side by side, right (OD) then left (OS), as prescriptions are written.
struct VisionPrescriptionDetailView: View {
  let prescription: HealthVisionPrescription
  var now = Date.now

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        summary
        Text("Prescription")
          .font(.title3.bold())
          .padding(.top, 14)
        lenses
        VStack(spacing: 0) {
          row("Source", prescription.sourceName)
        }
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 14)
      }
      .padding(20)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.pageBackground)
    .navigationTitle(prescription.kind?.name ?? "Vision Prescription")
  }

  private var summary: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VisionPrescriptionIcon(kind: prescription.kind)
        VStack(alignment: .leading, spacing: 2) {
          Text(prescription.kind?.name ?? "Vision Prescription")
            .font(.title2.bold())
          if let brand = prescription.brand, !brand.isEmpty {
            Text(brand)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
      }
      .padding(14)
      Divider().padding(.leading, 14)
      row("Date Issued", prescription.issued.formatted(date: .long, time: .omitted))
      if let expires = prescription.expires {
        Divider().padding(.leading, 14)
        HStack {
          Text("Expiration Date")
          Spacer()
          if prescription.isExpired(at: now) {
            Text("Expired")
              .font(.caption.bold())
              .foregroundStyle(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.orange, in: Capsule())
          }
          Text(expires.formatted(date: .long, time: .omitted))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
      }
    }
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
  }

  private var lenses: some View {
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
    .padding(.horizontal, 14)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
  }

  private func row(_ name: String, _ value: String) -> some View {
    HStack {
      Text(name)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
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
    let kind = prescription.kind?.name ?? "Vision Prescription"
    guard let brand = prescription.brand, !brand.isEmpty else { return kind }
    return "\(kind) · \(brand)"
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
  /// amount at its angle, "2 Δ at 45°", for one given only that way. `nil` without either.
  static func prism(_ prism: VisionPrism, locale: Locale = .autoupdatingCurrent) -> String? {
    func amount(_ value: Double) -> String {
      "\(value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))) Δ"
    }
    let parts = [
      (prism.verticalAmount, prism.verticalBase), (prism.horizontalAmount, prism.horizontalBase),
    ]
    .compactMap { value, base -> String? in
      guard let value, value != 0, let base, base != .none else { return nil }
      return "\(amount(value)) Base \(base.name)"
    }
    if !parts.isEmpty { return parts.joined(separator: ", ") }
    guard let value = prism.amount, value != 0 else { return nil }
    guard let angle = prism.angle else { return amount(value) }
    return "\(amount(value)) at \(degrees(angle, locale: locale))"
  }
}
