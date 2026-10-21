import Foundation
import HealthDatabase
import SwiftUI

// In their own file, as All Data's are: the detail is a grouped `Form` of `ForEach` rows
// (AGENTS.md). Synthetic data only: foods made up here, passed in directly.

/// A synthetic food `daysAgo` days back at `hour`:`minute` today's time.
private func food(
  _ id: String, _ name: String?, daysAgo: Int, hour: Int, minute: Int = 0,
  energy: Double? = nil, carbohydrates: Double? = nil, protein: Double? = nil, fat: Double? = nil,
  source: String = "Synthetic Food Log"
) -> Food {
  let calendar = Calendar.current
  let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now))!
  let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
  return Food(
    id: id, name: name, startDate: start.unixMilliseconds,
    energy: energy, carbohydrates: carbohydrates, protein: protein, fat: fat, sourceName: source)
}

/// A few days of meals: some named, some not (a quick-added entry), some with only their energy.
private let foods = [
  food(
    "t3", "Greek Yogurt with Honey", daysAgo: 0, hour: 15, minute: 30, energy: 190,
    carbohydrates: 24.5, protein: 11, fat: 5.2),
  food(
    "t2", "Chicken Caesar Salad", daysAgo: 0, hour: 12, minute: 45, energy: 540,
    carbohydrates: 18, protein: 38, fat: 34),
  food(
    "t1", "Oatmeal with Blueberries", daysAgo: 0, hour: 8, minute: 10, energy: 310,
    carbohydrates: 54, protein: 9.5, fat: 6.1),
  food("y4", nil, daysAgo: 1, hour: 21, minute: 5, energy: 250, source: "Synthetic Quick Add"),
  food(
    "y3", "Spaghetti Bolognese with Parmesan and a Side of Garlic Bread", daysAgo: 1, hour: 19,
    energy: 890, carbohydrates: 102, protein: 41, fat: 33),
  food("y2", "Apple", daysAgo: 1, hour: 16, energy: 95),
  food("y1", nil, daysAgo: 1, hour: 13, minute: 20, carbohydrates: 40, protein: 22),
  food("w2", "Espresso", daysAgo: 2, hour: 9, minute: 40),
  food(
    "w1", "Avocado Toast", daysAgo: 2, hour: 8, energy: 420, carbohydrates: 38, protein: 12,
    fat: 24),
]

@MainActor
private func foodPage(_ state: FoodContent.State, moreFailed: Bool = false) -> some View {
  NavigationStack {
    FoodContent(state: state, moreFailed: moreFailed, loadMore: {})
  }
  .previewFrame(width: 620, height: 720)
}

#Preview("Food") {
  foodPage(.loaded(foods, hasMore: false))
}

#Preview("Food, empty") {
  foodPage(.loaded([], hasMore: false))
}

#Preview("Food, loading") {
  foodPage(.loading)
}

#Preview("Food, failed") {
  foodPage(.failed("The database couldn't be read."))
}

// The next page is loading: the last day's card stays open, and its total waits for its other
// foods.
#Preview("Food, loading more") {
  foodPage(.loaded(Array(foods.prefix(5)), hasMore: true))
}

// The next page failed: the last day's card closes, with a button to try again, and its total
// still waits.
#Preview("Food, more failed") {
  foodPage(.loaded(Array(foods.prefix(5)), hasMore: true), moreFailed: true)
}

private func nutrient(_ typeID: String, _ name: String, _ value: Double, _ unit: String)
  -> FoodNutrient
{
  FoodNutrient(
    id: typeID, typeID: "HKQuantityTypeIdentifier\(typeID)", name: name, value: value, unit: unit)
}

@MainActor
private func foodDetail(_ food: Food, _ state: FoodDetailContent.State) -> some View {
  NavigationStack {
    FoodDetailContent(food: food, state: state)
  }
  .previewFrame(width: 560, height: 620)
}

#Preview("A food") {
  foodDetail(
    foods[1],
    .loaded([
      nutrient("DietaryEnergyConsumed", "Dietary Energy", 540, "kcal"),
      nutrient("DietaryCarbohydrates", "Carbohydrates", 18, "g"),
      nutrient("DietaryFiber", "Fiber", 4.2, "g"),
      nutrient("DietarySugar", "Dietary Sugar", 3.1, "g"),
      nutrient("DietaryProtein", "Protein", 38, "g"),
      nutrient("DietaryFatTotal", "Total Fat", 34, "g"),
      nutrient("DietaryFatSaturated", "Saturated Fat", 8.4, "g"),
      nutrient("DietaryCholesterol", "Dietary Cholesterol", 95, "mg"),
      nutrient("DietarySodium", "Sodium", 1_120, "mg"),
      nutrient("DietaryCalcium", "Calcium", 210, "mg"),
      nutrient("DietaryVitaminC", "Vitamin C", 22, "mg"),
    ]))
}

// A quick-added entry: no name, only its energy.
#Preview("A food without a name") {
  foodDetail(foods[3], .loaded([nutrient("DietaryEnergyConsumed", "Dietary Energy", 250, "kcal")]))
}

#Preview("A food, no nutrients") {
  foodDetail(foods[7], .loaded([]))
}

#Preview("A food, loading") {
  foodDetail(foods[1], .loading)
}

#Preview("A food, failed") {
  foodDetail(foods[1], .failed("The database couldn't be read."))
}
