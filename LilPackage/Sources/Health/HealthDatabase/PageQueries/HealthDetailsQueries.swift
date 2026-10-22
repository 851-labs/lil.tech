public import Foundation
public import HealthCatalog
public import SQLiteData

extension HealthDatabase {
  /// Every synced characteristic (date of birth, sex…), by type identifier.
  public static func characteristics(_ db: Database) throws -> [HealthCharacteristic] {
    try HealthCharacteristic.order { $0.id }.fetchAll(db)
  }
}

/// Health Details, the profile Health keeps: date of birth, sex, blood type, skin type and
/// wheelchair use, as the iPhone encodes them (`HealthEncoder`). `nil` is Not Set, as Health shows
/// a value that was never set, or one this app can't read.
public struct HealthDetails: Equatable, Sendable {
  public var dateOfBirth: BirthDate?
  public var sex: BiologicalSex?
  public var bloodType: BloodType?
  public var skinType: FitzpatrickSkinType?
  public var wheelchairUse: WheelchairUse?
  /// Whether any of these five characteristics has synced, even one Not Set: if not, the iPhone
  /// hasn't shared them.
  public var hasSynced: Bool

  /// The characteristics Health Details shows, by type identifier.
  public static let characteristicIDs: Set<String> = [
    "DateOfBirth", "BiologicalSex", "BloodType", "FitzpatrickSkinType", "WheelchairUse",
  ].reduce(into: []) { $0.insert("HKCharacteristicTypeIdentifier\($1)") }

  /// Whether lil health for Mac has a page for the type, which its Open intent, sidebar search and
  /// `lil-health open` agree on: a type with a category opens in it, and a characteristic Health
  /// Details shows opens Health Details (851-3026). Activity Move Mode, which it doesn't show, is
  /// nowhere in the app.
  public static func hasPage(_ type: HealthDataType) -> Bool {
    type.category != nil || characteristicIDs.contains(type.id)
  }

  public init(
    dateOfBirth: BirthDate? = nil, sex: BiologicalSex? = nil, bloodType: BloodType? = nil,
    skinType: FitzpatrickSkinType? = nil, wheelchairUse: WheelchairUse? = nil,
    hasSynced: Bool = false
  ) {
    self.dateOfBirth = dateOfBirth
    self.sex = sex
    self.bloodType = bloodType
    self.skinType = skinType
    self.wheelchairUse = wheelchairUse
    self.hasSynced = hasSynced
  }

  /// From the synced rows. A value that can't be read, or is an unknown case, is Not Set.
  public init(characteristics: [HealthCharacteristic]) {
    let values = Dictionary(
      characteristics.map { ($0.id, Data($0.value.utf8)) }, uniquingKeysWith: { first, _ in first })
    func decoded<Value: Decodable>(_ id: String) -> Value? {
      values["HKCharacteristicTypeIdentifier\(id)"].flatMap {
        try? JSONDecoder().decode(Value.self, from: $0)
      }
    }
    func named<Value: RawRepresentable<String>>(_ id: String) -> Value? {
      (decoded(id) as String?).flatMap(Value.init(rawValue:))
    }
    self.init(
      dateOfBirth: decoded("DateOfBirth"), sex: named("BiologicalSex"),
      bloodType: named("BloodType"), skinType: named("FitzpatrickSkinType"),
      wheelchairUse: named("WheelchairUse"),
      hasSynced: characteristics.contains { Self.characteristicIDs.contains($0.id) })
  }
}

/// A day of birth in the Gregorian calendar, as HealthKit gives it.
public struct BirthDate: Equatable, Sendable, Decodable {
  public var year: Int
  public var month: Int
  public var day: Int

  public init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  /// Its start in `calendar`'s time zone, to show in that calendar.
  public func date(in calendar: Calendar) -> Date? {
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = calendar.timeZone
    return gregorian.date(from: DateComponents(year: year, month: month, day: day))
  }

  /// How old someone born on it is at `now`, in whole years.
  public func age(at now: Date, calendar: Calendar) -> Int? {
    guard let birth = date(in: calendar), birth <= now else { return nil }
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = calendar.timeZone
    return gregorian.dateComponents([.year], from: birth, to: now).year
  }
}

/// `HKBiologicalSex`, as the iPhone names it.
public enum BiologicalSex: String, Sendable {
  case female, male, other

  public var name: String {
    switch self {
    case .female: "Female"
    case .male: "Male"
    case .other: "Other"
    }
  }
}

/// `HKBloodType`, as the iPhone names it.
public enum BloodType: String, Sendable {
  case aPositive, aNegative, bPositive, bNegative, abPositive, abNegative, oPositive, oNegative

  public var name: String {
    switch self {
    case .aPositive: "A+"
    case .aNegative: "A−"
    case .bPositive: "B+"
    case .bNegative: "B−"
    case .abPositive: "AB+"
    case .abNegative: "AB−"
    case .oPositive: "O+"
    case .oNegative: "O−"
    }
  }
}

/// `HKFitzpatrickSkinType`, as the iPhone names it.
public enum FitzpatrickSkinType: String, Sendable {
  case typeI = "I"
  case typeII = "II"
  case typeIII = "III"
  case typeIV = "IV"
  case typeV = "V"
  case typeVI = "VI"

  public var name: String { "Type \(rawValue)" }
}

/// `HKWheelchairUse`, as the iPhone names it.
public enum WheelchairUse: String, Sendable {
  case yes, no

  public var name: String { self == .yes ? "Yes" : "No" }
}
