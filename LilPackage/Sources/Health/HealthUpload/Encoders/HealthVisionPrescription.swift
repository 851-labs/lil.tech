import Foundation
public import HealthKit

extension HealthEncoder {
  public static let visionPrescriptionEntity = "health_vision_prescription"

  /// A glasses or contacts prescription: each eye's lens in diopters, degrees and millimeters, and
  /// when it expires (`HealthVisionPrescription` on the server). Its start and end are the date
  /// it was issued: HealthKit ends it in the far future. `nil` for a kind that's neither, which the
  /// server wouldn't take.
  public static func visionPrescription(_ prescription: HKVisionPrescription) -> HealthMutation? {
    var row = provenance(of: prescription)
    row["endDate"] = .number(milliseconds(prescription.dateIssued))
    row["prescriptionType"] = JSONValue(Int(prescription.prescriptionType.rawValue))
    row["expirationDate"] = JSONValue(prescription.expirationDate.map(milliseconds))
    row["brand"] = .null
    switch prescription {
    case let glasses as HKGlassesPrescription:
      row["rightEye"] = lens(glasses.rightEye)
      row["leftEye"] = lens(glasses.leftEye)
    case let contacts as HKContactsPrescription:
      row["brand"] = .string(contacts.brand)
      row["rightEye"] = lens(contacts.rightEye)
      row["leftEye"] = lens(contacts.leftEye)
    default:
      return nil
    }
    return .upsert(visionPrescriptionEntity, id: id(prescription.uuid), row: row)
  }

  /// A quantity in `unit`, or null if it has none or another kind of unit: converting it would
  /// raise an exception, which a Swift `catch` can't stop.
  private static func value(_ quantity: HKQuantity?, _ unit: HKUnit) -> JSONValue {
    guard let quantity, quantity.is(compatibleWith: unit) else { return .null }
    return .number(quantity.doubleValue(for: unit))
  }

  /// A lens: what both kinds have, then glasses' or contacts' own values. Null without a sphere
  /// in diopters, which every lens has.
  private static func lens(_ lens: HKLensSpecification?) -> JSONValue {
    let diopters = HKUnit.diopter()
    guard let lens, case .number = value(lens.sphere, diopters) else { return .null }
    let degrees = HKUnit.degreeAngle()
    let millimeters = HKUnit.meterUnit(with: .milli)
    var values: [String: JSONValue] = [
      "sphere": value(lens.sphere, diopters),
      "cylinder": value(lens.cylinder, diopters),
      "axis": value(lens.axis, degrees),
      "addPower": value(lens.addPower, diopters),
    ]
    if let glasses = lens as? HKGlassesLensSpecification {
      values["vertexDistance"] = value(glasses.vertexDistance, millimeters)
      values["farPupillaryDistance"] = value(glasses.farPupillaryDistance, millimeters)
      values["nearPupillaryDistance"] = value(glasses.nearPupillaryDistance, millimeters)
      let prismDiopters = HKUnit.prismDiopter()
      values["prism"] =
        glasses.prism.map { prism in
          .object([
            "amount": value(prism.amount, prismDiopters),
            "angle": value(prism.angle, degrees),
            "verticalAmount": value(prism.verticalAmount, prismDiopters),
            "verticalBase": JSONValue(Int(prism.verticalBase.rawValue)),
            "horizontalAmount": value(prism.horizontalAmount, prismDiopters),
            "horizontalBase": JSONValue(Int(prism.horizontalBase.rawValue)),
          ])
        } ?? .null
    } else if let contacts = lens as? HKContactsLensSpecification {
      values["baseCurve"] = value(contacts.baseCurve, millimeters)
      values["diameter"] = value(contacts.diameter, millimeters)
    }
    return .object(values)
  }
}
