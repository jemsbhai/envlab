import Foundation

/// What the wearer said after "Hey Dewin".
enum VoiceCommand: Equatable {
    case capture
    case question(String)

    private static let questionWords: Set = ["how", "what", "whats", "what's", "did", "have", "has", "much", "many",
                                             "was", "were", "is", "tell", "left", "remaining", "total"]

    /// `remainder` is everything after the wake phrase. Empty or "log this" → capture.
    static func parse(_ remainder: String) -> VoiceCommand {
        let words = MealQA.words(remainder)
        guard !words.isEmpty else { return .capture }
        let asks = words.contains { questionWords.contains($0) }
        let mentionsNutrition = words.contains { MealQA.metric(for: $0) != nil }
        return asks || mentionsNutrition ? .question(remainder) : .capture
    }
}

/// Answers spoken questions about logged meals, on the phone, from SwiftData.
/// Rule-based: it looks for a nutrient, a time range, and optionally a food name.
enum MealQA {
    enum Metric: String {
        case calories, protein, carbs, fat, fiber, sugar, sodium, score

        var unitWord: String {
            switch self {
            case .calories: "calories"
            case .sodium: "milligrams of sodium"
            case .score: ""
            default: "grams of \(self == .carbs ? "carbs" : rawValue)"
            }
        }

        func value(_ n: Nutrients) -> Double? {
            switch self {
            case .calories: n.calories
            case .protein: n.proteinG
            case .carbs: n.carbsG
            case .fat: n.fatG
            case .fiber: n.fiberG
            case .sugar: n.sugarG
            case .sodium: n.sodiumMg
            case .score: nil
            }
        }

        /// Daily target, and whether it's a ceiling (sugar, sodium) rather than a goal.
        func target(_ goals: Goals) -> (value: Double, isLimit: Bool)? {
            switch self {
            case .calories: (goals.calories, false)
            case .protein: (goals.proteinG, false)
            case .carbs: (goals.carbsG, false)
            case .fat: (goals.fatG, false)
            case .fiber: (goals.fiberG, false)
            case .sugar: (goals.sugarMaxG, true)
            case .sodium: (goals.sodiumMaxMg, true)
            case .score: nil
            }
        }
    }

    enum Scope: Equatable {
        case today, yesterday, week
        case slot(MealSlot, dayOffset: Int)
        case lastMeal
    }

    static func metric(for word: String) -> Metric? {
        switch word {
        case "calorie", "calories", "cal", "cals", "kcal", "kilocalories", "energy": .calories
        case "protein", "proteins": .protein
        case "carb", "carbs", "carbohydrate", "carbohydrates": .carbs
        case "fat", "fats": .fat
        case "fiber", "fibre": .fiber
        case "sugar", "sugars": .sugar
        case "sodium", "salt": .sodium
        case "score", "healthy", "health", "healthiest": .score
        default: nil
        }
    }

    // MARK: Answer

    static func answer(_ question: String, meals: [Meal], goals: Goals, now: Date = .now,
                       calendar: Calendar = .current) -> String {
        let words = words(question)
        let metric = words.lazy.compactMap { metric(for: $0) }.first ?? .calories
        let scope = scope(words)
        let wantsRemaining = words.contains("left") || words.contains("remaining")
        let foodWords = foodWords(words)
        let analyzed = meals.filter { $0.status == .analyzed }

        // A specific food: "my tomato sandwich", "the pizza".
        // Without a day, "my tomato sandwich" searches the past week.
        if !foodWords.isEmpty {
            let foodScope = scope == .today && !mentionsTime(words) ? .week : scope
            let pool = analyzed.filter { inScope($0, foodScope, now: now, calendar: calendar) }
            if let (meal, item) = bestMatch(foodWords, in: pool) {
                return describe(meal: meal, item: item, metric: metric, calendar: calendar, now: now)
            }
            // Only a clear food question ("calories in my …") gets a not-found; otherwise the
            // leftover words were filler and the question is about totals.
            if words.contains("in") || words.contains("my") || words.contains("the") {
                return "I couldn't find \(foodWords.joined(separator: " ")) in your log\(scopePhrase(foodScope, suffix: true))."
            }
        }

        if scope == .lastMeal {
            guard let meal = analyzed.max(by: { $0.capturedAt < $1.capturedAt }) else { return "You haven't logged a meal yet." }
            return describe(meal: meal, item: nil, metric: metric, calendar: calendar, now: now)
        }

        let inRange = analyzed.filter { inScope($0, scope, now: now, calendar: calendar) }
        let pendingCount = meals.filter { [.review, .queued, .sent, .analyzing].contains($0.status) && inScope($0, scope, now: now, calendar: calendar) }.count
        let pendingNote = pendingCount > 0 ? " That doesn't include \(pendingCount) photo\(pendingCount == 1 ? "" : "s") not analyzed yet." : ""

        guard !inRange.isEmpty else {
            return "You haven't logged anything\(scopePhrase(scope, suffix: true)) yet.\(pendingNote)"
        }

        if metric == .score {
            let day = DaySummary(day: now, meals: inRange)
            guard let score = day.healthScore else { return "I don't have health scores\(scopePhrase(scope, suffix: true))." }
            return "Your health score\(scopePhrase(scope, suffix: true)) is \(Int(score.rounded())) out of 100.\(pendingNote)"
        }

        let total = inRange.compactMap { metric.value($0.nutrients) }.reduce(0, +)

        if case .week = scope {
            let days = Set(inRange.map { calendar.startOfDay(for: $0.capturedAt) }).count
            let average = total / Double(max(days, 1))
            return "This week you've averaged \(spoken(average)) \(metric.unitWord) a day over \(days) day\(days == 1 ? "" : "s")."
        }

        if case let .slot(slot, _) = scope {
            let names = inRange.compactMap(\.name)
            let list = names.isEmpty ? "" : ": \(listPhrase(names))"
            return "\(slot.name.capitalized) was \(spoken(total)) \(metric.unitWord)\(list).\(pendingNote)"
        }

        var sentence = "You've had \(spoken(total)) \(metric.unitWord)\(scopePhrase(scope, suffix: true))."
        if scope == .today, let target = metric.target(goals) {
            let difference = target.value - speechRounded(total)
            if wantsRemaining || !target.isLimit {
                sentence = difference >= 0
                    ? (wantsRemaining
                        ? "You have \(spoken(difference)) \(metric.unitWord) left today, out of \(spoken(target.value))."
                        : sentence + " That leaves \(spoken(difference)) of your \(spoken(target.value)) goal.")
                    : sentence + " That's \(spoken(-difference)) over your goal."
            } else if difference < 0 {
                sentence += " That's over your \(spoken(target.value)) limit."
            }
        }
        return sentence + pendingNote
    }

    // MARK: Parsing helpers

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
    }

    private static func scope(_ words: [String]) -> Scope {
        let dayOffset = words.contains("yesterday") || words.contains("yesterdays") ? -1 : 0
        for slot in MealSlot.allCases where words.contains(slot.rawValue) || words.contains(slot.rawValue + "s") {
            return .slot(slot, dayOffset: dayOffset)
        }
        if words.contains("supper") { return .slot(.dinner, dayOffset: dayOffset) }
        if dayOffset == -1 { return .yesterday }
        if words.contains("week") || words.contains("weekly") { return .week }
        if words.contains("last") && (words.contains("meal") || words.contains("ate")) { return .lastMeal }
        if words.contains("just") && words.contains("ate") { return .lastMeal }
        return .today
    }

    private static func mentionsTime(_ words: [String]) -> Bool {
        words.contains("today") || words.contains("tonight") || words.contains("morning")
    }

    private static let stopWords: Set = [
        "hey", "dewin", "devin", "how", "many", "much", "what", "whats", "was", "were", "is", "are", "in", "my", "the", "a", "an",
        "did", "do", "i", "eat", "ate", "eaten", "have", "had", "has", "today", "yesterday", "yesterdays", "for", "at",
        "of", "this", "that", "week", "weekly", "so", "far", "total", "left", "remaining", "there", "it", "me", "tell",
        "about", "from", "with", "to", "on", "last", "meal", "meals", "just", "food", "foods", "get", "got", "consume",
        "consumed", "intake", "all", "day", "and", "or", "be", "would", "you", "your", "please", "can", "could",
        "gram", "grams", "g", "mg", "milligrams", "amount", "number", "contain", "contained", "contains", "tonight",
        "morning", "lunchtime", "supper", "s", "us", "im", "ive", "been", "eating", "drink", "drank", "some",
        "am", "doing", "going", "does", "track", "tracking", "looking", "overall", "average", "averaging", "far",
        "okay", "ok", "dewan", "duin", "hi", "hay", "should", "more", "enough", "too", "high", "low", "lot",
    ]

    private static func foodWords(_ words: [String]) -> [String] {
        words.filter { word in
            !stopWords.contains(word) && metric(for: word) == nil
                && !MealSlot.allCases.contains { $0.rawValue == word || $0.rawValue + "s" == word }
                && Int(word) == nil
        }
    }

    private static func inScope(_ meal: Meal, _ scope: Scope, now: Date, calendar: Calendar) -> Bool {
        let today = calendar.startOfDay(for: now)
        switch scope {
        case .today:
            return calendar.isDate(meal.capturedAt, inSameDayAs: today)
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return false }
            return calendar.isDate(meal.capturedAt, inSameDayAs: yesterday)
        case .week:
            guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return false }
            return meal.capturedAt >= start
        case let .slot(slot, offset):
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return false }
            return calendar.isDate(meal.capturedAt, inSameDayAs: day) && MealSlot(for: meal.capturedAt, calendar: calendar) == slot
        case .lastMeal:
            return true
        }
    }

    /// Scores meals by how many of the spoken food words appear in the meal or item names.
    /// "the bread in my tomato sandwich" → the sandwich meal, then its bread item.
    private static func bestMatch(_ foodWords: [String], in meals: [Meal]) -> (Meal, MealResultMessage.Item?)? {
        let wanted = Set(foodWords.map(singular))
        func nameWords(_ name: String) -> Set<String> { Set(words(name).map(singular)) }

        var best: (meal: Meal, item: MealResultMessage.Item?, score: Int)?
        for meal in meals.sorted(by: { $0.capturedAt > $1.capturedAt }) {
            let mealWords = nameWords(meal.name ?? "")
            let mealScore = mealWords.intersection(wanted).count
            // Words the meal name didn't explain may point at one of its items.
            let leftover = mealScore > 0 ? wanted.subtracting(mealWords) : wanted
            var item: MealResultMessage.Item?
            var itemScore = 0
            for candidate in meal.items {
                let score = nameWords(candidate.name).intersection(leftover).count
                if score > itemScore { (item, itemScore) = (candidate, score) }
            }
            let score = mealScore + itemScore
            if score > (best?.score ?? 0) { best = (meal, item, score) }
        }
        return best.map { ($0.meal, $0.item) }
    }

    private static func singular(_ word: String) -> String {
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("es"), word.count > 4, ["ches", "shes", "toes", "sses"].contains(where: word.hasSuffix) {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 3 { return String(word.dropLast()) }
        return word
    }

    // MARK: Phrasing

    private static func describe(meal: Meal, item: MealResultMessage.Item?, metric: Metric,
                                 calendar: Calendar, now: Date) -> String {
        let when = whenPhrase(meal.capturedAt, calendar: calendar, now: now)
        if let item {
            guard let value = item.nutrients.flatMap({ metric.value($0) }) else {
                return "I don't have \(metric.rawValue) for the \(item.name.lowercased()) in your \(meal.name?.lowercased() ?? "meal")."
            }
            return "The \(item.name.lowercased()) in your \(when) \(meal.name?.lowercased() ?? "meal") had about \(spoken(value)) \(metric.unitWord)."
        }
        let name = meal.name?.lowercased() ?? "meal"
        if metric == .score {
            guard let score = meal.healthScore else { return "I don't have a health score for your \(name)." }
            return "Your \(when) \(name) scored \(Int(score.rounded())) out of 100."
        }
        guard let value = metric.value(meal.nutrients) else { return "I don't have \(metric.rawValue) for your \(name)." }
        return "Your \(when) \(name) had about \(spoken(value)) \(metric.unitWord)."
    }

    private static func whenPhrase(_ date: Date, calendar: Calendar, now: Date) -> String {
        let slot = MealSlot(for: date, calendar: calendar).name
        if calendar.isDate(date, inSameDayAs: now) { return slot }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "\(slot) yesterday"
        }
        return "\(date.formatted(.dateTime.weekday(.wide))) \(slot)"
    }

    private static func scopePhrase(_ scope: Scope, suffix: Bool) -> String {
        switch scope {
        case .today: " today"
        case .yesterday: " yesterday"
        case .week: " this week"
        case let .slot(slot, offset): " at \(slot.name) \(offset == -1 ? "yesterday" : "today")"
        case .lastMeal: ""
        }
    }

    /// Round the way people say numbers: 1,234 → "1,230"; 46.4 → "46".
    private static func spoken(_ value: Double) -> String {
        Int(speechRounded(value)).formatted()
    }

    /// So "you've had X, that leaves Y" adds up to the goal as spoken.
    private static func speechRounded(_ value: Double) -> Double {
        value >= 200 ? (value / 10).rounded() * 10 : value.rounded()
    }

    private static func listPhrase(_ names: [String]) -> String {
        let lower = names.map { $0.lowercased() }
        guard lower.count > 1 else { return lower.first ?? "" }
        return lower.dropLast().joined(separator: ", ") + " and " + lower.last!
    }
}
