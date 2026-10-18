#if DEBUG
import Foundation
import SwiftData

/// Fills the past week with analyzed meals (from the mock backend's menu) so the
/// dashboards can be checked without logging dozens of photos.
enum DemoData {
    @MainActor
    static func seedWeek(into context: ModelContext, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: .now)
        let hours = [8, 13, 19]
        for dayOffset in 0...6 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            for hour in hours {
                guard let time = calendar.date(byAdding: .hour, value: hour, to: day), time <= .now else { continue }
                let meal = Meal(photo: nil, source: "demo", trigger: "demo", capturedAt: time)
                meal.apply(MockBackend.sample(for: UUID().uuidString))
                context.insert(meal)
            }
        }
        try? context.save()
    }

    /// A known meal for the voice self-test: "how many calories were in my tomato sandwich?"
    @MainActor
    static func addTomatoSandwichLunch(into context: ModelContext, calendar: Calendar = .current) {
        guard let noon = calendar.date(bySettingHour: 12, minute: 30, second: 0, of: .now) else { return }
        let meal = Meal(photo: nil, source: "demo", trigger: "demo", capturedAt: noon)
        typealias Item = MealResultMessage.Item
        let items = [
            Item(name: "Sourdough bread", portion: "2 slices",
                 nutrients: Nutrients(calories: 240, proteinG: 8, carbsG: 46, fatG: 2, fiberG: 2, sugarG: 2, sodiumMg: 480)),
            Item(name: "Tomato", portion: "4 slices",
                 nutrients: Nutrients(calories: 22, proteinG: 1, carbsG: 5, fatG: 0, fiberG: 1.5, sugarG: 3, sodiumMg: 6)),
            Item(name: "Mayonnaise", portion: "1 tbsp",
                 nutrients: Nutrients(calories: 94, proteinG: 0, carbsG: 0, fatG: 10, fiberG: 0, sugarG: 0, sodiumMg: 88)),
        ]
        let totals = items.compactMap(\.nutrients).reduce(.zero, +)
        meal.status = .analyzed
        meal.name = "Tomato sandwich"
        meal.calories = totals.calories
        meal.proteinG = totals.proteinG
        meal.carbsG = totals.carbsG
        meal.fatG = totals.fatG
        meal.fiberG = totals.fiberG
        meal.sugarG = totals.sugarG
        meal.sodiumMg = totals.sodiumMg
        meal.healthScore = 62
        meal.itemsData = try? JSONEncoder().encode(items)
        context.insert(meal)
        try? context.save()
    }
}
#endif
