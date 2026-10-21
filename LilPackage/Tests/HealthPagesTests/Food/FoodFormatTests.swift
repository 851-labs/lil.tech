import Foundation
import HealthDatabase
import Testing

@testable import HealthPages

// Synthetic data only (AGENTS.md).

struct FoodFormatTests {
  private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
  // 2025-10-15 12:00 UTC.
  private let now = Date(timeIntervalSince1970: 1_760_529_600)

  private func food(
    energy: Double? = nil, carbohydrates: Double? = nil, protein: Double? = nil,
    fat: Double? = nil
  ) -> Food {
    Food(
      id: "f", name: nil, startDate: 1_760_529_600_000,
      energy: energy, carbohydrates: carbohydrates, protein: protein, fat: fat,
      sourceName: "Food Log")
  }

  @Test
  func macronutrientsLeaveOutWhatAFoodLacks() {
    #expect(
      FoodFormat.macronutrients(food(carbohydrates: 62, protein: 18, fat: 21))
        == "Carbs \(62.formatted()) g · Protein \(18.formatted()) g · Fat \(21.formatted()) g")
    #expect(FoodFormat.macronutrients(food(protein: 9.5)) == "Protein \(9.5.formatted()) g")
    #expect(FoodFormat.macronutrients(food(energy: 250)) == nil)
  }

  @Test
  func dayHeadersAddTheEnergyOnlyOnceTheDayIsComplete() {
    let day = FoodDay(
      day: utc.startOfDay(for: now), foods: [food(energy: 1_200), food(energy: 640)])
    let total = 1_840.formatted(.number.precision(.fractionLength(0)))
    #expect(
      FoodFormat.dayHeader(day, isComplete: true, now: now, calendar: utc)
        == "Today · \(total) kcal")
    #expect(FoodFormat.dayHeader(day, isComplete: false, now: now, calendar: utc) == "Today")
    let noEnergy = FoodDay(day: utc.startOfDay(for: now), foods: [food(protein: 3)])
    #expect(FoodFormat.dayHeader(noEnergy, isComplete: true, now: now, calendar: utc) == "Today")
  }
}
