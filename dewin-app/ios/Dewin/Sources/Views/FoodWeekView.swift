import Charts
import SwiftData
import SwiftUI

/// Food › Week: calories and health score over 7 days, averages, tips, best and worst meals.
struct FoodWeekView: View {
    @Query(sort: \Meal.capturedAt) private var meals: [Meal]

    var body: some View {
        let goals = Goals.current
        let week = Insights.week(from: meals)
        let logged = week.filter { $0.mealCount > 0 }
        let weekTotals = logged.map(\.totals).reduce(.zero, +)
        let days = Double(max(logged.count, 1))

        List {
            Section("Calories") {
                Chart {
                    ForEach(week) { day in
                        BarMark(
                            x: .value("Day", day.day, unit: .day),
                            y: .value("Calories", day.totals.calories ?? 0)
                        )
                        .foregroundStyle((day.totals.calories ?? 0) > goals.calories * 1.1 ? Color.orange : Color.green)
                    }
                    RuleMark(y: .value("Goal", goals.calories))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Goal").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) {
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .frame(height: 180)
                .padding(.vertical, 6)

                LabeledContent("Daily average", value: "\(Int((weekTotals.calories ?? 0) / days).formatted()) cal")
                LabeledContent("Days logged", value: "\(logged.count) of 7")
                LabeledContent("Meals logged", value: "\(logged.reduce(0) { $0 + $1.mealCount })")
            }

            Section("Health score") {
                Chart {
                    ForEach(week) { day in
                        if let score = day.healthScore {
                            LineMark(x: .value("Day", day.day, unit: .day), y: .value("Score", score))
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("Day", day.day, unit: .day), y: .value("Score", score))
                                .foregroundStyle(HealthScoreBadge.color(for: score))
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) {
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .frame(height: 140)
                .padding(.vertical, 6)
            }

            Section("Health breakdown (daily average)") {
                if let split = DaySummary(day: .now, meals: logged.flatMap(\.analyzed)).macroSplit {
                    MacroSplitBar(protein: split.protein, carbs: split.carbs, fat: split.fat)
                        .padding(.vertical, 4)
                }
                NutrientBar(label: "Protein", value: (weekTotals.proteinG ?? 0) / days, target: goals.proteinG, unit: "g")
                NutrientBar(label: "Fiber", value: (weekTotals.fiberG ?? 0) / days, target: goals.fiberG, unit: "g")
                NutrientBar(label: "Sugar", value: (weekTotals.sugarG ?? 0) / days, target: goals.sugarMaxG, unit: "g", isLimit: true)
                NutrientBar(label: "Sodium", value: (weekTotals.sodiumMg ?? 0) / days, target: goals.sodiumMaxMg, unit: "mg", isLimit: true)
            }

            Section("Tips") {
                ForEach(Insights.weekTips(week, goals: goals)) { TipRow(tip: $0) }
            }

            let scored = logged.flatMap(\.analyzed).filter { $0.healthScore != nil }
            if scored.count >= 2 {
                let sorted = scored.sorted { ($0.healthScore ?? 0) > ($1.healthScore ?? 0) }
                Section("Best meals") {
                    ForEach(sorted.prefix(3)) { meal in NavigationLink(value: meal) { MealRow(meal: meal) } }
                }
                Section("Watch-outs") {
                    ForEach(sorted.suffix(3).reversed()) { meal in NavigationLink(value: meal) { MealRow(meal: meal) } }
                }
            }
        }
    }
}

/// Protein / carbs / fat share of calories as one stacked bar.
struct MacroSplitBar: View {
    let protein: Double
    let carbs: Double
    let fat: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(.blue).frame(width: geo.size.width * protein)
                    Rectangle().fill(.green).frame(width: geo.size.width * carbs)
                    Rectangle().fill(.orange).frame(width: max(0, geo.size.width * fat - 4))
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
            HStack {
                legend("Protein", protein, .blue)
                legend("Carbs", carbs, .green)
                legend("Fat", fat, .orange)
            }
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
    }

    private func legend(_ name: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(name) \(Int((value * 100).rounded()))%").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
