import Foundation

/// Daily targets. Defaults follow common adult guidance (FDA Daily Values: sodium < 2,300 mg,
/// fiber 28 g, added sugar < 50 g); the user can change them in Settings.
struct Goals: Equatable {
    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fiberG: Double
    var sugarMaxG: Double
    var sodiumMaxMg: Double

    static let defaults = Goals(calories: 2000, proteinG: 120, carbsG: 225, fatG: 70,
                                fiberG: 28, sugarMaxG: 50, sodiumMaxMg: 2300)

    static let keys: [WritableKeyPath<Goals, Double>: String] = [
        \.calories: "goal.calories", \.proteinG: "goal.protein", \.carbsG: "goal.carbs", \.fatG: "goal.fat",
        \.fiberG: "goal.fiber", \.sugarMaxG: "goal.sugarMax", \.sodiumMaxMg: "goal.sodiumMax",
    ]

    static var current: Goals {
        var goals = Goals.defaults
        for (path, key) in keys {
            let value = UserDefaults.standard.double(forKey: key)
            if value > 0 { goals[keyPath: path] = value }
        }
        return goals
    }
}

/// Totals for one calendar day of analyzed meals.
struct DaySummary: Identifiable {
    let day: Date
    let meals: [Meal]

    var id: Date { day }
    var analyzed: [Meal] { meals.filter { $0.status == .analyzed } }
    var totals: Nutrients { analyzed.map(\.nutrients).reduce(.zero, +) }
    var mealCount: Int { analyzed.count }

    /// Calorie-weighted, so a snack doesn't count as much as dinner.
    var healthScore: Double? {
        let scored = analyzed.compactMap { meal in meal.healthScore.map { ($0, max(meal.calories ?? 1, 1)) } }
        let weight = scored.reduce(0) { $0 + $1.1 }
        guard weight > 0 else { return nil }
        return scored.reduce(0) { $0 + $1.0 * $1.1 } / weight
    }

    /// Share of calories from protein, carbs and fat (4/4/9 kcal per gram).
    var macroSplit: (protein: Double, carbs: Double, fat: Double)? {
        let t = totals
        let p = (t.proteinG ?? 0) * 4, c = (t.carbsG ?? 0) * 4, f = (t.fatG ?? 0) * 9
        let sum = p + c + f
        guard sum > 0 else { return nil }
        return (p / sum, c / sum, f / sum)
    }
}

enum Insights {
    static func day(_ date: Date, from meals: [Meal], calendar: Calendar = .current) -> DaySummary {
        let start = calendar.startOfDay(for: date)
        return DaySummary(day: start, meals: meals.filter { calendar.isDate($0.capturedAt, inSameDayAs: start) })
    }

    /// The 7 days ending today, oldest first, including empty days.
    static func week(endingOn date: Date = .now, from meals: [Meal], calendar: Calendar = .current) -> [DaySummary] {
        let today = calendar.startOfDay(for: date)
        return (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { day($0, from: meals, calendar: calendar) }
        }
    }

    struct Tip: Identifiable, Hashable {
        enum Kind { case good, warning, info }
        let kind: Kind
        let text: String
        var id: String { text }
    }

    /// Rule-based tips for a day, then the latest meal's tip from the backend.
    static func tips(for day: DaySummary, goals: Goals, now: Date = .now, calendar: Calendar = .current) -> [Tip] {
        guard day.mealCount > 0 else {
            return [Tip(kind: .info, text: "Say \"Hey Dewin\" or double-press the capture button to log your first meal.")]
        }
        var tips: [Tip] = []
        let t = day.totals
        let isToday = calendar.isDateInToday(day.day)
        let dayFraction = isToday ? dayProgress(now, calendar: calendar) : 1

        if let sodium = t.sodiumMg, sodium > goals.sodiumMaxMg {
            tips.append(.init(kind: .warning, text: "Sodium is \(Int(sodium)) mg, over the \(Int(goals.sodiumMaxMg)) mg limit. Go easy on sauces and processed food for the rest of the day."))
        } else if let sodium = t.sodiumMg, sodium > goals.sodiumMaxMg * 0.8, isToday, dayFraction < 0.7 {
            tips.append(.init(kind: .warning, text: "Already at \(Int(sodium / goals.sodiumMaxMg * 100))% of your sodium limit."))
        }
        if let sugar = t.sugarG, sugar > goals.sugarMaxG {
            tips.append(.init(kind: .warning, text: "Sugar is at \(Int(sugar)) g, above your \(Int(goals.sugarMaxG)) g target."))
        }
        if let protein = t.proteinG, protein < goals.proteinG * 0.5, dayFraction > 0.6 {
            tips.append(.init(kind: .info, text: "Protein is \(Int(protein)) of \(Int(goals.proteinG)) g. A protein-heavy dinner would close the gap."))
        }
        if let fiber = t.fiberG, fiber < goals.fiberG * 0.4, dayFraction > 0.6 {
            tips.append(.init(kind: .info, text: "Fiber is low (\(Int(fiber)) g). Beans, vegetables or whole grains help."))
        } else if let fiber = t.fiberG, fiber >= goals.fiberG {
            tips.append(.init(kind: .good, text: "Fiber goal hit: \(Int(fiber)) g."))
        }
        if let calories = t.calories {
            if calories > goals.calories * 1.1 {
                tips.append(.init(kind: .warning, text: "\(Int(calories - goals.calories)) calories over your goal."))
            } else if isToday, dayFraction > 0.85, calories < goals.calories * 0.6 {
                tips.append(.init(kind: .info, text: "Only \(Int(calories)) calories so far. Make sure you're eating enough."))
            }
        }
        if let score = day.healthScore, score >= 75 {
            tips.append(.init(kind: .good, text: "Strong day: average health score \(Int(score))."))
        }
        if let latest = day.analyzed.max(by: { $0.capturedAt < $1.capturedAt }), let tip = latest.tips.first {
            tips.append(.init(kind: .info, text: "\(latest.name ?? "Last meal"): \(tip)"))
        }
        return tips
    }

    /// Week-level patterns.
    static func weekTips(_ week: [DaySummary], goals: Goals) -> [Tip] {
        let logged = week.filter { $0.mealCount > 0 }
        guard logged.count >= 2 else {
            return [Tip(kind: .info, text: "Log a few days of meals to see weekly patterns.")]
        }
        var tips: [Tip] = []
        let avg = { (path: KeyPath<Nutrients, Double?>) in
            logged.compactMap { $0.totals[keyPath: path] }.reduce(0, +) / Double(logged.count)
        }
        let overSodium = logged.filter { ($0.totals.sodiumMg ?? 0) > goals.sodiumMaxMg }.count
        if overSodium >= 3 {
            tips.append(.init(kind: .warning, text: "Over the sodium limit on \(overSodium) of \(logged.count) days."))
        }
        let protein = avg(\.proteinG)
        if protein < goals.proteinG * 0.75 {
            tips.append(.init(kind: .info, text: "Averaging \(Int(protein)) g protein a day, below your \(Int(goals.proteinG)) g goal."))
        }
        let fiber = avg(\.fiberG)
        if fiber >= goals.fiberG {
            tips.append(.init(kind: .good, text: "Averaging \(Int(fiber)) g fiber a day. Nice."))
        }
        let scores = logged.compactMap(\.healthScore)
        if scores.count >= 2, let first = scores.first, let last = scores.last, last - first >= 10 {
            tips.append(.init(kind: .good, text: "Health score is trending up this week."))
        }
        if tips.isEmpty {
            tips.append(.init(kind: .good, text: "A steady week, close to your goals."))
        }
        return tips
    }

    private static func dayProgress(_ now: Date, calendar: Calendar) -> Double {
        let start = calendar.startOfDay(for: now)
        return now.timeIntervalSince(start) / 86_400
    }
}
