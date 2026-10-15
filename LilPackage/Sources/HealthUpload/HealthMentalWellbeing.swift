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
    row["kind"] = JSONValue(log.kind.rawValue)
    row["valence"] = .number(log.valence)
    row["valenceClassification"] = JSONValue(log.valenceClassification.rawValue)
    row["labels"] = .array(log.labels.map { JSONValue($0.rawValue) })
    row["associations"] = .array(log.associations.map { JSONValue($0.rawValue) })
    return .upsert(stateOfMindEntity, id: id(log.uuid), row: row)
  }

  /// A GAD-7 or PHQ-9 assessment: its score, risk and each answer's raw value. Other assessment
  /// types aren't known yet, so they're unsupported.
  public static func scoredAssessment(_ assessment: HKScoredAssessment) throws -> HealthMutation {
    var row = provenance(of: assessment)
    row["type"] = .string(assessment.sampleType.identifier)
    row["score"] = JSONValue(assessment.score)
    let (risk, answers): (Int, [Int])
    switch assessment {
    case let gad7 as HKGAD7Assessment:
      (risk, answers) = (gad7.risk.rawValue, gad7.answers.map(\.rawValue))
    case let phq9 as HKPHQ9Assessment:
      (risk, answers) = (phq9.risk.rawValue, phq9.answers.map(\.rawValue))
    default: throw UnsupportedSample(type: assessment.sampleType.identifier)
    }
    row["risk"] = JSONValue(risk)
    row["answers"] = .array(answers.map { JSONValue($0) })
    return .upsert(scoredAssessmentEntity, id: id(assessment.uuid), row: row)
  }
}
