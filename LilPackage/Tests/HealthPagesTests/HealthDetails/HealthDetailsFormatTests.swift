import Foundation
import HealthDatabase
import Testing

@testable import HealthPages

// Synthetic data only (AGENTS.md).

private let locale = Locale(identifier: "en_US")

private func utcCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}

struct HealthDetailsFormatTests {
  @Test
  func rowsAreHealthsWithNotSetForWhatIsnt() {
    let calendar = utcCalendar()
    let now = calendar.date(from: DateComponents(year: 2025, month: 10, day: 14))!
    let details = HealthDetails(
      dateOfBirth: BirthDate(year: 1990, month: 4, day: 2), bloodType: .aPositive,
      wheelchairUse: .yes)
    #expect(
      HealthDetailsFormat.rows(details, now: now, calendar: calendar, locale: locale) == [
        .init(name: "Date of Birth", value: "Apr 2, 1990 (age 35)"),
        .init(name: "Sex", value: "Not Set"),
        .init(name: "Blood Type", value: "A+"),
        .init(name: "Fitzpatrick Skin Type", value: "Not Set"),
        .init(name: "Wheelchair", value: "Yes"),
      ])
    #expect(
      HealthDetailsFormat.rows(HealthDetails(), now: now, calendar: calendar, locale: locale)
        .allSatisfy { $0.value == "Not Set" })
  }
}

struct VisionFormatTests {
  @Test
  func dioptersAreSignedWithTwoDecimals() {
    #expect(VisionFormat.diopters(1.25, locale: locale) == "+1.25")
    #expect(VisionFormat.diopters(-2, locale: locale) == "−2.00")
    #expect(VisionFormat.diopters(0, locale: locale) == "0.00")
    #expect(VisionFormat.diopters(-0.001, locale: locale) == "0.00")
    #expect(VisionFormat.degrees(90, locale: locale) == "90°")
    #expect(VisionFormat.millimeters(12, locale: locale) == "12 mm")
    #expect(VisionFormat.millimeters(31.5, locale: locale) == "31.5 mm")
  }

  @Test
  func prismsReadTowardTheirBases() {
    #expect(
      VisionFormat.prism(
        VisionPrism(
          amount: 1.12, angle: 63.4, verticalAmount: 1, verticalBase: .up, horizontalAmount: 0.5,
          horizontalBase: .inward),
        locale: locale) == "1 Δ Base Up, 0.5 Δ Base In")
    #expect(
      VisionFormat.prism(VisionPrism(amount: 2, angle: 45), locale: locale) == "2 Δ at 45°")
    #expect(
      VisionFormat.prism(
        VisionPrism(amount: 0, verticalAmount: 0, verticalBase: .down), locale: locale) == nil)
  }

  @Test
  func aPrismWithABaseItCantReadIsntShownInPart() throws {
    // The horizontal base is from a newer iOS: its amount and angle instead, or nothing.
    let json = Data(
      #"{"amount":1.5,"angle":20,"verticalAmount":1,"verticalBase":1,"horizontalAmount":0.5,"horizontalBase":9}"#
        .utf8)
    var prism = try JSONDecoder().decode(VisionPrism.self, from: json)
    #expect(prism.horizontalBase == nil)
    #expect(VisionFormat.prism(prism, locale: locale) == "1.5 Δ at 20°")
    prism.amount = nil
    #expect(VisionFormat.prism(prism, locale: locale) == nil)
    #expect(
      VisionFormat.rows(right: VisionLens(sphere: 1, prism: prism), left: nil, locale: locale)
        .first { $0.name == "Prism" } == nil)
  }

  @Test
  func rowsLeaveOutWhatNeitherEyeHas() {
    let right = VisionLens(
      sphere: -3.5, cylinder: -1.25, axis: 90, baseCurve: 8.6, diameter: 14.2)
    let left = VisionLens(sphere: -3, baseCurve: 8.6, diameter: 14.2)
    #expect(
      VisionFormat.rows(right: right, left: left, locale: locale) == [
        .init(name: "Sphere", right: "−3.50", left: "−3.00"),
        .init(name: "Cylinder", right: "−1.25", left: "–"),
        .init(name: "Axis", right: "90°", left: "–"),
        .init(name: "Base Curve", right: "8.6 mm", left: "8.6 mm"),
        .init(name: "Diameter", right: "14.2 mm", left: "14.2 mm"),
      ])
    // One eye only: sphere still shows for both.
    #expect(
      VisionFormat.rows(right: nil, left: VisionLens(sphere: -0.25), locale: locale) == [
        .init(name: "Sphere", right: "–", left: "−0.25")
      ])
  }

  @Test
  func titlesNameContactsBrand() {
    let contacts = HealthVisionPrescription(
      id: "a", startDate: 0, endDate: 0, prescriptionType: 2, brand: "Daily Comfort",
      sourceName: "Health", sourceBundleID: "com.apple.Health")
    #expect(VisionFormat.title(contacts) == "Contacts · Daily Comfort")
  }
}
