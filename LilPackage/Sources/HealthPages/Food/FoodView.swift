import Dependencies
import HealthDatabase
import HealthUI
import SQLiteData
public import SwiftUI

/// Food (851-2833), which Health doesn't have: the foods apps logged (Food correlations), newest
/// first, in a section per day with the day's energy, a page at a time as the list scrolls, as All
/// Data is. Each shows its name, energy and macronutrients, and opens all its nutrients.
public struct FoodView: View {
  @Dependency(\.defaultDatabase) private var database
  @State private var state = FoodContent.State.loading
  @State private var isLoadingMore = false
  /// The last page after the first failed to load.
  @State private var moreFailed = false

  static let pageSize = 200

  public init() {}

  public var body: some View {
    FoodContent(state: state, moreFailed: moreFailed) {
      Task { await loadMore() }
    }
    .task {
      // Only the first time: coming back from a food doesn't load another page.
      if case .loading = state { await loadMore() }
    }
  }

  private func loadMore() async {
    let loaded: [Food]
    switch state {
    case .loaded(let foods, hasMore: true): loaded = foods
    case .loading: loaded = []
    case .loaded, .failed: return
    }
    guard !isLoadingMore else { return }
    isLoadingMore = true
    moreFailed = false
    defer { isLoadingMore = false }
    let (cursor, limit) = (loaded.last?.cursor, Self.pageSize)
    do {
      let page = try await database.read { db in
        try HealthDatabase.foodPage(after: cursor, limit: limit, db)
      }
      state = .loaded(loaded + page, hasMore: page.count == Self.pageSize)
    } catch {
      if loaded.isEmpty {
        state = .failed(error.localizedDescription)
      } else {
        moreFailed = true
      }
    }
  }
}

/// What Food shows, however it got it.
struct FoodContent: View {
  enum State {
    case loading
    case loaded([Food], hasMore: Bool)
    case failed(String)
  }

  let state: State
  var moreFailed = false
  let loadMore: () -> Void
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.date.now) private var now
  @Dependency(\.calendar) private var calendar

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load Food", systemImage: "exclamationmark.triangle",
          description: Text(reason)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded(let foods, _) where foods.isEmpty:
        ContentUnavailableView(
          "No Food", systemImage: "fork.knife",
          description: Text("Food logged in apps that write to Health will appear here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded(let foods, let hasMore):
        list(foods, hasMore: hasMore)
      }
    }
    .navigationTitle("Food")
  }

  /// A section per day under its name and energy, in a grouped form's look, as All Data's
  /// (`LazyForm`, so only the rows on screen are built).
  private func list(_ foods: [Food], hasMore: Bool) -> some View {
    // Read once: a dependency's `now` is the time each time it's read.
    let now = now
    let calendar = calendar
    let days = HealthDatabase.foodDays(foods, calendar: calendar)
    return LazyForm {
      // The last day may go on in the next page, so its section stays open while that loads. Its
      // total, which would leave those foods out, waits for them, even once loading more failed.
      LazyFormSections(
        days, start: \.day, records: \.foods,
        title: { day in
          FoodFormat.dayHeader(
            day, isComplete: !(hasMore && day.day == days.last?.day), now: now, calendar: calendar)
        },
        isOpen: hasMore && !moreFailed
      ) { food in
        FoodDetailView(food: food)
      } row: { food in
        FoodRow(food: food, calendar: calendar)
      }
      Group {
        if moreFailed {
          Button("Couldn't load more. Try Again", action: loadMore)
        } else if hasMore {
          // Loads the next page when the end of the list comes into view.
          ProgressView()
            .onAppear(perform: loadMore)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 12)
    }
  }
}

/// A food: its name, macronutrients and app, and its energy and time.
struct FoodRow: View {
  let food: Food
  let calendar: Calendar

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(food.title)
          .font(.body.weight(.semibold))
          .foregroundStyle(food.name == nil ? .secondary : .primary)
          .lineLimit(2)
        if let macronutrients = FoodFormat.macronutrients(food) {
          Text(macronutrients)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Text(food.sourceName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        if let energy = food.energy {
          let (number, unit) = FoodFormat.energy(energy)
          HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(number)
              .font(.body.weight(.semibold))
              .monospacedDigit()
            Text(unit)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        Text(FoodFormat.time(food, calendar: calendar))
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// One food's details: when and where it was logged, and every nutrient it has.
struct FoodDetailView: View {
  let food: Food
  @Dependency(\.defaultDatabase) private var database
  @State private var state = FoodDetailContent.State.loading

  var body: some View {
    FoodDetailContent(food: food, state: state)
      .task {
        do {
          let nutrients = try await database.read { [id = food.id] db in
            try HealthDatabase.foodNutrients(of: id, db)
          }
          state = .loaded(nutrients)
        } catch {
          state = .failed(error.localizedDescription)
        }
      }
  }
}

/// What a food's details show, however they got them.
struct FoodDetailContent: View {
  enum State {
    case loading
    case loaded([FoodNutrient])
    case failed(String)
  }

  let food: Food
  let state: State

  var body: some View {
    Form {
      Section {
        LabeledContent("Time", value: food.start, format: .dateTime)
        LabeledContent("App", value: food.sourceName)
      }
      Section("Nutrients") {
        switch state {
        case .loading:
          ProgressView()
            .frame(maxWidth: .infinity)
        case .failed(let reason):
          Label("Couldn't load its nutrients: \(reason)", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        case .loaded(let nutrients) where nutrients.isEmpty:
          Text("No nutrients were logged with this food.")
            .foregroundStyle(.secondary)
        case .loaded(let nutrients):
          ForEach(nutrients) { nutrient in
            LabeledContent(nutrient.name, value: FoodFormat.nutrient(nutrient))
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(food.title)
  }
}

/// How Food writes its values and times.
enum FoodFormat {
  /// ("1,840", "kcal").
  static func energy(_ kilocalories: Double) -> (number: String, unit: String) {
    MetricFormat.value(kilocalories, unit: "kcal", typeID: HealthDatabase.dietaryEnergyType)
  }

  /// "Carbs 62 g · Protein 18 g · Fat 21 g", leaving out what the food doesn't have: nil if it
  /// has none.
  static func macronutrients(_ food: Food) -> String? {
    let parts: [(String, Double?, String)] = [
      ("Carbs", food.carbohydrates, HealthDatabase.dietaryCarbohydratesType),
      ("Protein", food.protein, HealthDatabase.dietaryProteinType),
      ("Fat", food.fat, HealthDatabase.dietaryFatType),
    ]
    let written = parts.compactMap { name, grams, typeID in
      grams.map { grams in
        let (number, unit) = MetricFormat.value(grams, unit: "g", typeID: typeID)
        return "\(name) \(number) \(unit)"
      }
    }
    return written.isEmpty ? nil : written.joined(separator: " · ")
  }

  /// A day's name and its foods' energy: "Today · 1,840 kcal", or the name alone for a day with
  /// no energy, or one whose foods aren't all loaded yet.
  static func dayHeader(
    _ day: FoodDay, isComplete: Bool, now: Date, calendar: Calendar
  ) -> String {
    let name = MetricFormat.date(day.day, isDay: true, now: now, calendar: calendar)
    guard isComplete, let energy = day.energy else { return name }
    let (number, unit) = Self.energy(energy)
    return "\(name) · \(number) \(unit)"
  }

  /// "8:15 AM", in the calendar's time zone.
  static func time(_ food: Food, calendar: Calendar) -> String {
    food.start.formatted(
      Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute())
  }

  /// "62 g".
  static func nutrient(_ nutrient: FoodNutrient) -> String {
    let (number, unit) = MetricFormat.value(
      nutrient.value, unit: nutrient.unit, typeID: nutrient.typeID)
    return unit.isEmpty ? number : "\(number) \(unit)"
  }
}
