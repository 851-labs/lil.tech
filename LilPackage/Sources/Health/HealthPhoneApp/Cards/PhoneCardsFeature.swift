import ComposableArchitecture
public import HealthCardEditor
import HealthKitAccess

// The iPhone's side of the shared `CardsFeature` (851-3993): loading until sync has pulled the
// cards, and the editor's filters' choices from HealthKit.

extension CardsFeature {
  /// The iPhone's cards: loading until sync has pulled them once (`LilSyncEngine.holds(_:_:)`),
  /// so a new iPhone shows Summary loading rather than empty before its first pull, with the
  /// filters' choices from HealthKit.
  public static var phone: Self {
    Self(filterChoices: .healthKit, waitsForSync: true)
  }
}

extension CardFilterChoicesClient {
  /// The apps and device models of a type's samples in this iPhone's HealthKit.
  static var healthKit: Self {
    Self { type in
      @Dependency(\.healthKitCards) var healthKitCards
      return try await healthKitCards.filterChoices(type)
    }
  }
}
