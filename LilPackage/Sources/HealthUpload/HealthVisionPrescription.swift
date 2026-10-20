import Foundation
public import HealthKit

extension HealthEncoder {
  public static let visionPrescriptionEntity = "health_vision_prescription"

  /// A glasses or contacts prescription: each eye's lens in diopters, degrees and millimeters, and
  /// when it expires (`HealthVisionPrescription` on the server). Its start and end are the date
  /// it was issued.
  public static func visionPrescription(_ prescription: HKVisionPrescription) -> HealthMutation {
    var row = provenance(of: prescription)
    row["prescriptionType"] = JSONValue(Int(prescription.prescriptionType.rawValue))
    row["expirationDate"] = JSONValue(prescription.expirationDate.map(milliseconds))
    switch prescription {
    case let glasses as HKGlassesPrescription:
      row["brand"] = .null
      row["rightEye"] = lens(glasses.rightEye)
      row["leftEye"] = lens(glasses.leftEye)
    case let contacts as HKContactsPrescription:
      row["brand"] = .string(contacts.brand)
      row["rightEye"] = lens(contacts.rightEye)
      row["leftEye"] = lens(contacts.leftEye)
    default:
      row["brand"] = .null
      row["rightEye"] = .null
      row["leftEye"] = .null
    }
    return .upsert(visionPrescriptionEntity, id: id(prescription.uuid), row: row)
  }

  /// A lens: what both kinds have, then glasses' or contacts' own values.
  private static func lens(_ lens: HKLensSpecification?) -> JSONValue {
    guard let lens else { return .null }
    let diopters = HKUnit.diopter()
    let degrees = HKUnit.degreeAngle()
    let millimeters = HKUnit.meterUnit(with: .milli)
    var values: [String: JSONValue] = [
      "sphere": .number(lens.sphere.doubleValue(for: diopters)),
      "cylinder": JSONValue(lens.cylinder?.doubleValue(for: diopters)),
      "axis": JSONValue(lens.axis?.doubleValue(for: degrees)),
      "addPower": JSONValue(lens.addPower?.doubleValue(for: diopters)),
    ]
    if let glasses = lens as? HKGlassesLensSpecification {
      values["vertexDistance"] = JSONValue(glasses.vertexDistance?.doubleValue(for: millimeters))
      values["farPupillaryDistance"] = JSONValue(
        glasses.farPupillaryDistance?.doubleValue(for: millimeters))
      values["nearPupillaryDistance"] = JSONValue(
        glasses.nearPupillaryDistance?.doubleValue(for: millimeters))
      let prismDiopters = HKUnit.prismDiopter()
      values["prism"] =
        glasses.prism.map { prism in
          .object([
            "amount": .number(prism.amount.doubleValue(for: prismDiopters)),
            "angle": .number(prism.angle.doubleValue(for: degrees)),
            "verticalAmount": .number(prism.verticalAmount.doubleValue(for: prismDiopters)),
            "verticalBase": JSONValue(Int(prism.verticalBase.rawValue)),
            "horizontalAmount": .number(prism.horizontalAmount.doubleValue(for: prismDiopters)),
            "horizontalBase": JSONValue(Int(prism.horizontalBase.rawValue)),
          ])
        } ?? .null
    } else if let contacts = lens as? HKContactsLensSpecification {
      values["baseCurve"] = JSONValue(contacts.baseCurve?.doubleValue(for: millimeters))
      values["diameter"] = JSONValue(contacts.diameter?.doubleValue(for: millimeters))
    }
    return .object(values)
  }
}
