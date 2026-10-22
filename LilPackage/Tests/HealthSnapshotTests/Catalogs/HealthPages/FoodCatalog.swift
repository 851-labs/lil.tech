#if os(macOS)
  import Foundation
  import HealthDatabase
  @testable import HealthPages
  import SwiftUI
  import Testing

  // Food (`FoodView`) and a food's nutrients (`FoodDetailContent`), logged in the days up to
  // `previewNow`. Synthetic data only: foods made up here, passed in directly.

  extension MacSnapshotTests {
    @Test(arguments: foodCatalog.selectedStates)
    func food(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let foodCatalog = StateCatalog(
    "Food", width: 620, minHeight: 720,
    states: [
      CatalogState("Food") { foodPage(.loaded(foods, hasMore: false)) },
      CatalogState("Food, empty") { foodPage(.loaded([], hasMore: false)) },
      CatalogState("Food, loading") { foodPage(.loading) },
      CatalogState("Food, failed") { foodPage(.failed("The database couldn't be read.")) },
      // The next page is loading: the last day's card stays open, and its total waits for its
      // other foods.
      CatalogState("Food, loading more") {
        foodPage(.loaded(Array(foods.prefix(5)), hasMore: true))
      },
      // The next page failed: the last day's card closes, with a button to try again, and its
      // total still waits.
      CatalogState("Food, more failed") {
        foodPage(.loaded(Array(foods.prefix(5)), hasMore: true), moreFailed: true)
      },
      CatalogState("A food", width: 560, minHeight: 620) {
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
      },
      // A quick-added entry: no name, only its energy.
      CatalogState("A food without a name", width: 560, minHeight: 620) {
        foodDetail(
          foods[3], .loaded([nutrient("DietaryEnergyConsumed", "Dietary Energy", 250, "kcal")]))
      },
      CatalogState("A food, no nutrients", width: 560, minHeight: 620) {
        foodDetail(foods[7], .loaded([]))
      },
      CatalogState("A food, loading", width: 560, minHeight: 620) {
        foodDetail(foods[1], .loading)
      },
      CatalogState("A food, failed", width: 560, minHeight: 620) {
        foodDetail(foods[1], .failed("The database couldn't be read."))
      },
    ])

  /// A synthetic food `daysAgo` days before `previewNow`'s day, at `hour`:`minute`.
  private func food(
    _ id: String, _ name: String?, daysAgo: Int, hour: Int, minute: Int = 0,
    energy: Double? = nil, carbohydrates: Double? = nil, protein: Double? = nil,
    fat: Double? = nil, source: String = "Synthetic Food Log"
  ) -> Food {
    let calendar = previewCalendar
    let day = calendar.date(
      byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: previewNow))!
    let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    return Food(
      id: id, name: name, startDate: start.unixMilliseconds,
      energy: energy, carbohydrates: carbohydrates, protein: protein, fat: fat, sourceName: source)
  }

  /// A few days of meals: some named, some not (a quick-added entry), some with only their
  /// energy. Today's are before `previewNow`, 3 PM.
  private let foods = [
    food(
      "t3", "Greek Yogurt with Honey", daysAgo: 0, hour: 14, minute: 30, energy: 190,
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

  private func nutrient(_ typeID: String, _ name: String, _ value: Double, _ unit: String)
    -> FoodNutrient
  {
    FoodNutrient(
      id: typeID, typeID: "HKQuantityTypeIdentifier\(typeID)", name: name, value: value,
      unit: unit)
  }

  @MainActor
  private func foodPage(_ state: FoodContent.State, moreFailed: Bool = false) -> some View {
    NavigationStack {
      FoodContent(state: state, moreFailed: moreFailed, loadMore: {})
    }
  }

  @MainActor
  private func foodDetail(_ food: Food, _ state: FoodDetailContent.State) -> some View {
    NavigationStack {
      FoodDetailContent(food: food, state: state)
    }
  }
#endif
