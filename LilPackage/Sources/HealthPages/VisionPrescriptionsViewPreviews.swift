import HealthDatabase
import HealthUI
import SwiftUI

// In their own file, as lists' previews are (AGENTS.md). Synthetic data only: made-up
// prescriptions.

private let now = Date(timeIntervalSince1970: 1_760_400_000)
private let day = 86_400_000

private func prescription(
  _ index: Int, _ kind: VisionPrescriptionKind, daysAgo: Int, validForDays: Int?,
  brand: String? = nil, right: String?, left: String?
) -> HealthVisionPrescription {
  let issued = now.unixMilliseconds - daysAgo * day
  return HealthVisionPrescription(
    id: "3d2b6a10-0000-4000-8000-\(String(format: "%012d", index))", startDate: issued,
    endDate: issued, prescriptionType: kind.rawValue,
    expirationDate: validForDays.map { issued + $0 * day }, brand: brand, rightEye: right,
    leftEye: left, sourceName: "Health", sourceBundleID: "com.apple.Health")
}

private let glassesWithPrism = prescription(
  1, .glasses, daysAgo: 40, validForDays: 730,
  right:
    #"{"sphere":2.25,"cylinder":-0.75,"axis":180,"addPower":1.5,"vertexDistance":12,"farPupillaryDistance":32,"nearPupillaryDistance":30.5,"prism":{"amount":1.12,"angle":63.4,"verticalAmount":1,"verticalBase":1,"horizontalAmount":0.5,"horizontalBase":3}}"#,
  left:
    #"{"sphere":1.75,"cylinder":-0.5,"axis":5,"addPower":1.5,"vertexDistance":12,"farPupillaryDistance":31.5,"nearPupillaryDistance":30,"prism":{"amount":1,"angle":270,"verticalAmount":1,"verticalBase":2,"horizontalAmount":null,"horizontalBase":0}}"#
)

private let contacts = prescription(
  2, .contacts, daysAgo: 500, validForDays: 365, brand: "Daily Comfort",
  right:
    #"{"sphere":-3.5,"cylinder":-1.25,"axis":90,"addPower":null,"baseCurve":8.6,"diameter":14.2}"#,
  left:
    #"{"sphere":-3,"cylinder":null,"axis":null,"addPower":null,"baseCurve":8.6,"diameter":14.2}"#
)

private let oneEye = prescription(
  3, .glasses, daysAgo: 900, validForDays: nil,
  right: nil,
  left:
    #"{"sphere":-0.25,"cylinder":null,"axis":null,"addPower":null,"vertexDistance":null,"farPupillaryDistance":null,"nearPupillaryDistance":null,"prism":null}"#
)

@MainActor
private func list(_ state: VisionPrescriptionsContent.State, limit: Int = 200) -> some View {
  NavigationStack {
    VisionPrescriptionsContent(state: state, limit: limit, now: now)
  }
  .previewFrame(width: 620, height: 420)
}

@MainActor
private func detail(_ prescription: HealthVisionPrescription?) -> some View {
  NavigationStack {
    VisionPrescriptionDetailContent(prescription: prescription, now: now)
  }
  .previewFrame(width: 760, height: 640)
}

#Preview("Vision prescriptions") {
  list(.loaded([glassesWithPrism, contacts, oneEye]))
}

#Preview("Vision prescriptions, at the limit") {
  list(.loaded([glassesWithPrism, contacts, oneEye]), limit: 3)
}

#Preview("No vision prescriptions") {
  list(.loaded([]))
}

#Preview("Vision prescriptions loading") {
  list(.loading)
}

#Preview("Vision prescriptions failed") {
  list(.failed("The database couldn't be read."))
}

#Preview("Glasses with prism") {
  detail(glassesWithPrism)
}

#Preview("Contacts, expired") {
  detail(contacts)
}

#Preview("One eye only") {
  detail(oneEye)
}

#Preview("Prescription no longer shared") {
  detail(nil)
}
