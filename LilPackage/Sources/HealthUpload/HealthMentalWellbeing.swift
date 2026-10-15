import Foundation
public import HealthKit

// State of Mind logs and scored assessments (GAD-7, PHQ-9), which are samples with their own
// fields (`HealthStateOfMind` and `HealthScoredAssessment` on the server).

extension HealthEncoder {
  public static let stateOfMindEntity = "health_state_of_mind"
  public static let scoredAssessmentEntity = "health_scored_assessment"

  /// A State of Mind log, with HealthKit's raw values for its kind, labels and associations.
  public static func stateOfMind(_ log: HKStateOfMind) -> HealthMutation {
    var row = provenance(of: log)
    row["kind"] = .number(Double(log.kind.rawValue))
    row["valence"] = .number(log.valence)
    row["valenceClassification"] = .number(Double(log.valenceClassification.rawValue))
    row["labels"] = .array(log.labels.map { .number(Double($0.rawValue)) })
    row["associations"] = .array(log.associations.map { .number(Double($0.rawValue)) })
    return .upsert(stateOfMindEntity, id: id(log.uuid), row: row)
  }

  /// A GAD-7 or PHQ-9 assessment: its score, risk and each answer's raw value. Other assessment
  /// types aren't known yet, so they're unsupported.
  public static func scoredAssessment(_ assessment: HKScoredAssessment) throws -> HealthMutation {
    var row = provenance(of: assessment)
    row["type"] = .string(assessment.sampleType.identifier)
    row["score"] = .number(Double(assessment.score))
    switch assessment {
    case let gad7 as HKGAD7Assessment:
      row["risk"] = .number(Double(gad7.risk.rawValue))
      row["answers"] = .array(gad7.answers.map { .number(Double($0.rawValue)) })
    case let phq9 as HKPHQ9Assessment:
      row["risk"] = .number(Double(phq9.risk.rawValue))
      row["answers"] = .array(phq9.answers.map { .number(Double($0.rawValue)) })
    default:
      throw UnsupportedSample(type: assessment.sampleType.identifier)
    }
    return .upsert(scoredAssessmentEntity, id: id(assessment.uuid), row: row)
  }
}
