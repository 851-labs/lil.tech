/// The Browse categories of iPad Health, in the order Health lists them.
///
/// Health Records isn't here: clinical records are out of scope (see `docs/DECISIONS.md`).
public enum HealthCategory: String, CaseIterable, Hashable, Identifiable, Sendable {
  case activity
  case bodyMeasurements
  case cycleTracking
  case hearing
  case heart
  case medications
  case mentalWellbeing
  case mobility
  case nutrition
  case respiratory
  case sleep
  case symptoms
  case vitals
  case otherData

  public var id: Self { self }

  /// The SF Symbol shown with the category.
  public var symbolName: String {
    switch self {
    case .activity: "flame.fill"
    case .bodyMeasurements: "figure"
    case .cycleTracking: "circle.dotted.circle"
    case .hearing: "ear"
    case .heart: "heart.fill"
    case .medications: "pills.fill"
    case .mentalWellbeing: "brain.head.profile"
    case .mobility: "figure.walk.motion"
    case .nutrition: "carrot.fill"
    case .respiratory: "lungs.fill"
    case .sleep: "bed.double.fill"
    case .symptoms: "list.bullet.clipboard"
    case .vitals: "waveform.path.ecg"
    case .otherData: "plus"
    }
  }

  public var name: String {
    switch self {
    case .activity: "Activity"
    case .bodyMeasurements: "Body Measurements"
    case .cycleTracking: "Cycle Tracking"
    case .hearing: "Hearing"
    case .heart: "Heart"
    case .medications: "Medications"
    case .mentalWellbeing: "Mental Wellbeing"
    case .mobility: "Mobility"
    case .nutrition: "Nutrition"
    case .respiratory: "Respiratory"
    case .sleep: "Sleep"
    case .symptoms: "Symptoms"
    case .vitals: "Vitals"
    case .otherData: "Other Data"
    }
  }
}
