public import Foundation
public import SQLiteData

extension HealthDatabase {
  /// State of Mind logs, newest first, at most `limit`.
  public static func stateOfMindLogs(limit: Int, _ db: Database) throws -> [HealthStateOfMind] {
    try HealthStateOfMind
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
  }

  /// The State of Mind logs that start in `range`, newest first (then by ID), at most `limit`,
  /// and how many there are in all: the `state_of_mind` tool's (851-4160).
  public static func stateOfMindLogs(in range: Range<Date>, limit: Int, _ db: Database) throws
    -> (count: Int, logs: [HealthStateOfMind])
  {
    let (lower, upper) = (range.lowerBound.unixMilliseconds, range.upperBound.unixMilliseconds)
    let inRange = HealthStateOfMind.where { $0.startDate >= lower && $0.startDate < upper }
    return (
      try inRange.fetchCount(db),
      try inRange.order { ($0.startDate.desc(), $0.id.desc()) }.limit(limit).fetchAll(db)
    )
  }

  /// The assessments of `kinds` that start in `range`, newest first (then by ID), at most
  /// `limit`, and how many there are in all: the `assessments` tool's (851-4160).
  public static func scoredAssessments(
    of kinds: [AssessmentKind], in range: Range<Date>, limit: Int, _ db: Database
  ) throws -> (count: Int, assessments: [HealthScoredAssessment]) {
    let (lower, upper) = (range.lowerBound.unixMilliseconds, range.upperBound.unixMilliseconds)
    let types = kinds.map(\.rawValue)
    let inRange = HealthScoredAssessment.where {
      $0.type.in(types) && $0.startDate >= lower && $0.startDate < upper
    }
    return (
      try inRange.fetchCount(db),
      try inRange.order { ($0.startDate.desc(), $0.id.desc()) }.limit(limit).fetchAll(db)
    )
  }

  /// A type's assessments (e.g. `HKScoredAssessmentTypeIdentifierGAD7`), newest first, at most
  /// `limit`.
  public static func scoredAssessments(of type: String, limit: Int, _ db: Database) throws
    -> [HealthScoredAssessment]
  {
    try HealthScoredAssessment
      .where { $0.type.eq(type) }
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
  }
}

/// How pleasant a State of Mind felt (`HKStateOfMind.ValenceClassification`), 1 to 7.
public enum ValenceClassification: Int, CaseIterable, Sendable {
  case veryUnpleasant = 1
  case unpleasant, slightlyUnpleasant, neutral, slightlyPleasant, pleasant
  case veryPleasant

  public var name: String {
    switch self {
    case .veryUnpleasant: "Very Unpleasant"
    case .unpleasant: "Unpleasant"
    case .slightlyUnpleasant: "Slightly Unpleasant"
    case .neutral: "Neutral"
    case .slightlyPleasant: "Slightly Pleasant"
    case .pleasant: "Pleasant"
    case .veryPleasant: "Very Pleasant"
    }
  }
}

/// HealthKit's State of Mind labels and associations, by raw value (`HKStateOfMind.Label` and
/// `.Association`, numbered from 1 in this order).
public enum StateOfMindVocabulary {
  public static let labels = [
    "Amazed", "Amused", "Angry", "Anxious", "Ashamed", "Brave", "Calm", "Content", "Disappointed",
    "Discouraged", "Disgusted", "Embarrassed", "Excited", "Frustrated", "Grateful", "Guilty",
    "Happy", "Hopeless", "Irritated", "Jealous", "Joyful", "Lonely", "Passionate", "Peaceful",
    "Proud", "Relieved", "Sad", "Scared", "Stressed", "Surprised", "Worried", "Annoyed",
    "Confident", "Drained", "Hopeful", "Indifferent", "Overwhelmed", "Satisfied",
  ]
  public static let associations = [
    "Community", "Current Events", "Dating", "Education", "Family", "Fitness", "Friends",
    "Health", "Hobbies", "Identity", "Money", "Partner", "Self Care", "Spirituality", "Tasks",
    "Travel", "Work", "Weather",
  ]

  /// Names for raw values, skipping ones this app doesn't know (from a newer iOS).
  static func names(_ json: String, in names: [String]) -> [String] {
    let values = (try? JSONDecoder().decode([Int].self, from: Data(json.utf8))) ?? []
    return values.compactMap { names.indices.contains($0 - 1) ? names[$0 - 1] : nil }
  }
}

extension HealthStateOfMind {
  /// Whether it's a daily mood (`HKStateOfMind.Kind` 2) rather than a momentary emotion (1).
  public var isDailyMood: Bool { kind == 2 }

  public var kindName: String { isDailyMood ? "Daily Mood" : "Momentary Emotion" }

  public var decodedValenceClassification: ValenceClassification? {
    ValenceClassification(rawValue: valenceClassification)
  }

  public var labelNames: [String] {
    StateOfMindVocabulary.names(labels, in: StateOfMindVocabulary.labels)
  }

  public var associationNames: [String] {
    StateOfMindVocabulary.names(associations, in: StateOfMindVocabulary.associations)
  }
}

/// The scored assessments Health has: GAD-7 (anxiety) and PHQ-9 (depression).
public enum AssessmentKind: String, CaseIterable, Sendable {
  case gad7 = "HKScoredAssessmentTypeIdentifierGAD7"
  case phq9 = "HKScoredAssessmentTypeIdentifierPHQ9"

  /// The highest score: 3 points a question.
  public var maximumScore: Int { self == .gad7 ? 21 : 27 }

  /// Risk names by raw value (`HKGAD7Assessment.Risk`, `HKPHQ9Assessment.Risk`), from 1.
  public var risks: [String] {
    switch self {
    case .gad7: ["None to Minimal", "Mild", "Moderate", "Severe"]
    case .phq9: ["None to Minimal", "Mild", "Moderate", "Moderately Severe", "Severe"]
    }
  }

  /// Where each risk starts, by score, for the chart's bands.
  public var riskThresholds: [Int] {
    switch self {
    case .gad7: [0, 5, 10, 15]
    case .phq9: [0, 5, 10, 15, 20]
    }
  }

  public func riskName(_ risk: Int) -> String {
    risks.indices.contains(risk - 1) ? risks[risk - 1] : "Unknown"
  }

  /// Answer names by raw value (`HKGAD7Assessment.Answer`, `HKPHQ9Assessment.Answer`), from 0:
  /// how often over the last two weeks. Only PHQ-9's 9th question can be skipped.
  public var answers: [String] {
    let frequencies = ["Not at all", "Several days", "More than half the days", "Nearly every day"]
    return self == .phq9 ? frequencies + ["Prefer not to answer"] : frequencies
  }

  public func answerName(_ answer: Int) -> String {
    answers.indices.contains(answer) ? answers[answer] : "Unknown"
  }
}
