public import Foundation
import HealthCatalog
public import SQLiteData

extension HealthDatabase {
  public static let foodType = "HKCorrelationTypeIdentifierFood"
  public static let dietaryEnergyType = "HKQuantityTypeIdentifierDietaryEnergyConsumed"
  public static let dietaryCarbohydratesType = "HKQuantityTypeIdentifierDietaryCarbohydrates"
  public static let dietaryProteinType = "HKQuantityTypeIdentifierDietaryProtein"
  public static let dietaryFatType = "HKQuantityTypeIdentifierDietaryFatTotal"
  /// `HKMetadataKeyFoodType`'s raw value: the food's name, as the app that logged it wrote it.
  static let foodNameKey = "HKFoodType"

  /// Up to `limit` foods (Food correlations), newest first, after `cursor` (the previous page's
  /// end), each with its energy and macronutrients from its samples (joined by
  /// `correlationID`). A food missing some of them still counts.
  public static func foodPage(
    after cursor: SampleCursor?, limit: Int, _ db: Database
  ) throws -> [Food] {
    let correlations =
      try HealthCorrelation
      .where { correlation in
        if let cursor {
          // The plain bound first, so SQLite can seek the (type, startDate) index to it.
          correlation.type.eq(foodType) && correlation.startDate <= cursor.startDate
            && (correlation.startDate < cursor.startDate || correlation.id < cursor.id)
        } else {
          correlation.type.eq(foodType)
        }
      }
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
    guard !correlations.isEmpty else { return [] }
    let summaryTypes = [
      dietaryEnergyType, dietaryCarbohydratesType, dietaryProteinType, dietaryFatType,
    ]
    let samples =
      try HealthSample
      .where {
        $0.correlationID.in(correlations.map { Optional.some($0.id) })
          && $0.type.in(summaryTypes)
      }
      .select { ($0.correlationID, $0.type, $0.value) }
      .fetchAll(db)
    // Each food's value of each type. A food has one sample of a type; should it have more, they
    // add up, as they would in Health's daily totals.
    var values: [String: [String: Double]] = [:]
    for (correlation, type, value) in samples {
      guard let correlation, let value else { continue }
      values[correlation, default: [:]][type, default: 0] += value
    }
    return correlations.map { correlation in
      let nutrients = values[correlation.id] ?? [:]
      return Food(
        id: correlation.id, name: foodName(metadata: correlation.metadata),
        startDate: correlation.startDate, endDate: correlation.endDate,
        energy: nutrients[dietaryEnergyType], carbohydrates: nutrients[dietaryCarbohydratesType],
        protein: nutrients[dietaryProteinType], fat: nutrients[dietaryFatType],
        sourceName: correlation.sourceName)
    }
  }

  /// The foods (newest first, as `foodPage` reads them) by day in `calendar`, each day with the
  /// total energy of its foods.
  public static func foodDays(_ foods: [Food], calendar: Calendar) -> [FoodDay] {
    var days: [FoodDay] = []
    var current: DateInterval?
    for food in foods {
      // The calendar only when a food leaves the day before it.
      if let current, current.contains(food.start), !days.isEmpty {
        days[days.count - 1].foods.append(food)
      } else {
        current = calendar.dateInterval(of: .day, for: food.start)
        days.append(FoodDay(day: current?.start ?? food.start, foods: [food]))
      }
    }
    return days
  }

  /// Every nutrient of one food (its samples), in the catalog's order of their types, then any
  /// type the catalog doesn't know, by identifier.
  public static func foodNutrients(of foodID: String, _ db: Database) throws -> [FoodNutrient] {
    try HealthSample
      .where { $0.correlationID.eq(foodID) }
      .fetchAll(db)
      .map { sample in
        let type = HealthCatalog.type(id: sample.type)
        return FoodNutrient(
          id: sample.id, typeID: sample.type, name: type?.name ?? sample.type,
          value: sample.value, unit: sample.unit ?? type?.unit)
      }
      .sorted { lhs, rhs in
        let (left, right) = (catalogOrder[lhs.typeID], catalogOrder[rhs.typeID])
        switch (left, right) {
        case (let left?, let right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return (lhs.typeID, lhs.id) < (rhs.typeID, rhs.id)
        }
      }
  }

  /// Each type's place in the catalog.
  private static let catalogOrder = Dictionary(
    uniqueKeysWithValues: HealthCatalog.all.enumerated().map { ($1.id, $0) })

  /// The name in a food's metadata (`HKFoodType`), if it has a nonblank one.
  static func foodName(metadata: String?) -> String? {
    guard let metadata,
      let object = try? JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any],
      let name = object[foodNameKey] as? String
    else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// A logged food: its name, when, its energy and macronutrients (each missing if the app didn't
/// log it), and the app that logged it.
public struct Food: Equatable, Identifiable, Sendable {
  public var id: String
  /// The name the app gave it (`HKFoodType`), if any.
  public var name: String?
  public var startDate: Int
  public var endDate: Int
  /// In kilocalories.
  public var energy: Double?
  /// In grams.
  public var carbohydrates: Double?
  public var protein: Double?
  public var fat: Double?
  public var sourceName: String

  public init(
    id: String, name: String?, startDate: Int, endDate: Int, energy: Double? = nil,
    carbohydrates: Double? = nil, protein: Double? = nil, fat: Double? = nil, sourceName: String
  ) {
    self.id = id
    self.name = name
    self.startDate = startDate
    self.endDate = endDate
    self.energy = energy
    self.carbohydrates = carbohydrates
    self.protein = protein
    self.fat = fat
    self.sourceName = sourceName
  }

  /// Its name, or "Food" for one logged without.
  public var title: String { name ?? "Food" }

  public var start: Date { Date(unixMilliseconds: startDate) }
  public var end: Date { Date(unixMilliseconds: endDate) }

  /// Where the page after the one ending with this food starts.
  public var cursor: SampleCursor { SampleCursor(startDate: startDate, id: id) }
}

/// A day's foods, newest first, with their total energy.
public struct FoodDay: Equatable, Sendable {
  /// The day's start.
  public var day: Date
  public var foods: [Food]

  public init(day: Date, foods: [Food]) {
    self.day = day
    self.foods = foods
  }

  /// The day's energy in kilocalories, from the foods that have it: nil if none does.
  public var energy: Double? {
    let energies = foods.compactMap(\.energy)
    return energies.isEmpty ? nil : energies.reduce(0, +)
  }
}

/// One of a food's nutrients: a sample of its correlation.
public struct FoodNutrient: Equatable, Identifiable, Sendable {
  /// The sample's ID.
  public var id: String
  public var typeID: String
  /// The catalog's name for the type, else its identifier.
  public var name: String
  public var value: Double?
  public var unit: String?

  public init(id: String, typeID: String, name: String, value: Double?, unit: String?) {
    self.id = id
    self.typeID = typeID
    self.name = name
    self.value = value
    self.unit = unit
  }
}
