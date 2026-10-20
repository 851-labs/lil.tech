import Foundation
import HealthDatabase
import SQLiteData
import Testing

// Synthetic data only (AGENTS.md).

private func characteristic(_ name: String, _ value: String) -> HealthCharacteristic {
  HealthCharacteristic(id: "HKCharacteristicTypeIdentifier\(name)", value: value)
}

private func utcCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}

@Suite
struct HealthDetailsTests {
  @Test
  func readsEachCharacteristicAsTheIPhoneEncodesIt() {
    let details = HealthDetails(characteristics: [
      characteristic("DateOfBirth", #"{"day":2,"month":4,"year":1990}"#),
      characteristic("BiologicalSex", #""female""#),
      characteristic("BloodType", #""abNegative""#),
      characteristic("FitzpatrickSkinType", #""IV""#),
      characteristic("WheelchairUse", #""no""#),
      characteristic("ActivityMoveMode", #""activeEnergy""#),
    ])
    #expect(
      details
        == HealthDetails(
          dateOfBirth: BirthDate(year: 1990, month: 4, day: 2), sex: .female,
          bloodType: .abNegative, skinType: .typeIV, wheelchairUse: .no))
    #expect(details.bloodType?.name == "AB−")
    #expect(details.skinType?.name == "Type IV")
  }

  @Test
  func notSetUnknownAndUnreadableValuesAreNotSet() {
    let details = HealthDetails(characteristics: [
      characteristic("DateOfBirth", #"{"day":2,"month":null,"year":1990}"#),
      characteristic("BiologicalSex", #""notSet""#),
      characteristic("BloodType", #""zPositive""#),
      characteristic("FitzpatrickSkinType", "oops"),
    ])
    #expect(details == HealthDetails(hasSynced: true))
    #expect(HealthDetails(characteristics: []) == HealthDetails(hasSynced: false))
  }

  @Test
  func ageCountsWholeYearsInTheUsersTimeZone() {
    let calendar = utcCalendar()
    let birth = BirthDate(year: 1990, month: 4, day: 2)
    let dayBefore = calendar.date(from: DateComponents(year: 2025, month: 4, day: 1, hour: 23))!
    let birthday = calendar.date(from: DateComponents(year: 2025, month: 4, day: 2))!
    #expect(birth.age(at: dayBefore, calendar: calendar) == 34)
    #expect(birth.age(at: birthday, calendar: calendar) == 35)
    // Not born yet.
    #expect(BirthDate(year: 2030, month: 1, day: 1).age(at: birthday, calendar: calendar) == nil)
  }

  @Test
  func characteristicsAreQueried() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthCharacteristic.insert {
        characteristic("BloodType", #""oPositive""#)
        characteristic("BiologicalSex", #""male""#)
      }
      .execute(db)
    }
    let rows = try database.read { db in try HealthDatabase.characteristics(db) }
    #expect(HealthDetails(characteristics: rows).bloodType == .oPositive)
    #expect(rows.count == 2)
  }
}

@Suite
struct VisionPrescriptionTests {
  private func prescription(
    _ id: String, start: Int, type: Int = 1, expires: Int? = nil, right: String? = nil,
    left: String? = nil
  ) -> HealthVisionPrescription {
    HealthVisionPrescription(
      id: id, startDate: start, endDate: start, prescriptionType: type, expirationDate: expires,
      rightEye: right, leftEye: left, sourceName: "Health", sourceBundleID: "com.apple.Health")
  }

  @Test
  func prescriptionsComeNewestFirst() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthVisionPrescription.insert {
        prescription("a", start: 1_000)
        prescription("b", start: 3_000, type: 2)
        prescription("c", start: 2_000)
      }
      .execute(db)
    }
    let all = try database.read { db in try HealthDatabase.visionPrescriptions(limit: 10, db) }
    #expect(all.map(\.id) == ["b", "c", "a"])
    #expect(all.map(\.kind) == [.contacts, .glasses, .glasses])
    let newest = try database.read { db in try HealthDatabase.visionPrescriptions(limit: 1, db) }
    #expect(newest.map(\.id) == ["b"])
  }

  @Test
  func lensesDecodeEachValueOnItsOwn() {
    let glasses = prescription(
      "a", start: 0,
      right:
        #"{"sphere":-1.25,"cylinder":-0.5,"axis":90,"addPower":null,"vertexDistance":12,"farPupillaryDistance":31.5,"nearPupillaryDistance":null,"prism":{"amount":1,"angle":90,"verticalAmount":1,"verticalBase":1,"horizontalAmount":0.5,"horizontalBase":3}}"#,
      left: #"{"sphere":"oops","cylinder":-0.25,"prism":{"verticalAmount":1,"verticalBase":9}}"#)
    #expect(
      glasses.decodedRightEye
        == VisionLens(
          sphere: -1.25, cylinder: -0.5, axis: 90, vertexDistance: 12, farPupillaryDistance: 31.5,
          prism: VisionPrism(
            amount: 1, angle: 90, verticalAmount: 1, verticalBase: .up, horizontalAmount: 0.5,
            horizontalBase: .inward)))
    // A value of the wrong kind, and a base from a newer iOS, are missing.
    #expect(
      glasses.decodedLeftEye
        == VisionLens(cylinder: -0.25, prism: VisionPrism(verticalAmount: 1)))
    #expect(prescription("b", start: 0, right: "oops").decodedRightEye == nil)
    #expect(prescription("c", start: 0).decodedLeftEye == nil)
  }

  @Test
  func expiresOnItsExpirationDate() {
    let expiring = prescription("a", start: 0, expires: 10_000)
    #expect(!expiring.isExpired(at: Date(unixMilliseconds: 9_999)))
    #expect(expiring.isExpired(at: Date(unixMilliseconds: 10_000)))
    #expect(!prescription("b", start: 0).isExpired(at: .distantFuture))
    #expect(prescription("c", start: 0, type: 3).kind == nil)
  }
}
