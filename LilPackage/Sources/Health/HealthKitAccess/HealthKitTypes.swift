public import HealthCatalog
public import HealthKit

extension HealthDataType {
  /// The HealthKit type to request and query, or `nil` for correlations (read through their
  /// components) and identifiers HealthKit doesn't know.
  public var objectType: HKObjectType? {
    switch kind {
    // The factory methods return nil for an unknown identifier; the initializers raise.
    case .quantity: HKObjectType.quantityType(forIdentifier: .init(rawValue: id))
    case .category: HKObjectType.categoryType(forIdentifier: .init(rawValue: id))
    case .characteristic: HKObjectType.characteristicType(forIdentifier: .init(rawValue: id))
    // There's no optional factory for these; `HealthCatalogTests` checks the identifiers.
    case .scoredAssessment: HKScoredAssessmentType(HKScoredAssessmentTypeIdentifier(rawValue: id))
    case .workout: HKObjectType.workoutType()
    case .workoutRoute: HKSeriesType.workoutRoute()
    case .activitySummary: HKObjectType.activitySummaryType()
    case .heartbeatSeries: HKSeriesType.heartbeat()
    case .electrocardiogram: HKObjectType.electrocardiogramType()
    case .audiogram: HKObjectType.audiogramSampleType()
    case .stateOfMind: HKObjectType.stateOfMindType()
    case .medication: HKObjectType.userAnnotatedMedicationType()
    case .medicationDoseEvent: HKObjectType.medicationDoseEventType()
    case .visionPrescription: HKObjectType.visionPrescriptionType()
    case .document: HKObjectType.documentType(forIdentifier: .init(rawValue: id))
    case .correlation: nil
    }
  }
}
