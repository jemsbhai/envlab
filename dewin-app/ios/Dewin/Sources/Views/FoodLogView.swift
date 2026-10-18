import SwiftData
import SwiftUI
import UIKit

/// Food › Log: every logged meal, grouped by day, newest first. Rows expand in place to show everything.
struct FoodLogView: View {
    @Environment(MealPipeline.self) private var pipeline
    @Query(sort: \Meal.capturedAt, order: .reverse) private var meals: [Meal]
    @State private var search = ""

    var body: some View {
        let calendar = Calendar.current
        let logged = meals.filter { $0.status != .review && matches($0) }
        let days = Dictionary(grouping: logged) { calendar.startOfDay(for: $0.capturedAt) }
            .sorted { $0.key > $1.key }

        List {
            if days.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "No meals yet" : "No matches",
                    systemImage: "fork.knife",
                    description: Text(search.isEmpty ? "Meals you send for analysis show up here." : "Try another food name.")
                )
            }
            ForEach(days, id: \.key) { day, dayMeals in
                Section {
                    ForEach(dayMeals) { meal in
                        ExpandableMealRow(meal: meal)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pipeline.delete(meal) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                    }
                } header: {
                    DayHeader(day: day, meals: dayMeals)
                }
            }
        }
        .searchable(text: $search, prompt: "Search foods")
    }

    private func matches(_ meal: Meal) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        if meal.name?.lowercased().contains(query) == true { return true }
        return meal.items.contains { $0.name.lowercased().contains(query) }
    }
}

private struct DayHeader: View {
    let day: Date
    let meals: [Meal]

    var body: some View {
        let calories = meals.filter { $0.status == .analyzed }.compactMap(\.calories).reduce(0, +)
        HStack {
            Text(title)
            Spacer()
            Text("\(Int(calories).formatted()) cal").monospacedDigit()
        }
        .textCase(nil)
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

/// A meal row that expands in place: photo, totals, ingredients, score, tags and tips.
struct ExpandableMealRow: View {
    @Environment(MealPipeline.self) private var pipeline
    let meal: Meal
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    MealRow(meal: meal)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapses details" : "Shows details")

            if expanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let photo = meal.photo, let image = UIImage(data: photo) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            HStack {
                Label(slotName, systemImage: "clock")
                Spacer()
                Text(meal.capturedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            switch meal.status {
            case .analyzed:
                analyzedDetails
            case .notFood, .failed:
                Text(meal.errorMessage ?? (meal.status == .notFood ? "This photo didn't look like food." : "The analysis failed."))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Try again") { Task { await pipeline.retry(meal) } }
            case .queued:
                Text("Waiting to send. It goes out automatically when the backend is connected.")
                    .font(.subheadline).foregroundStyle(.secondary)
            default:
                Text("Analyzing…").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var analyzedDetails: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            stat("Calories", meal.calories, "")
            stat("Protein", meal.proteinG, "g")
            stat("Carbs", meal.carbsG, "g")
            stat("Fat", meal.fatG, "g")
            stat("Fiber", meal.fiberG, "g")
            stat("Sugar", meal.sugarG, "g")
            stat("Sodium", meal.sodiumMg, "mg")
            VStack(spacing: 2) {
                HealthScoreBadge(score: meal.healthScore)
                Text("Score").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }

        if !meal.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("What's in it").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(meal.items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name).font(.subheadline)
                        if let portion = item.portion, !portion.isEmpty {
                            Text(portion).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let calories = item.nutrients?.calories {
                            Text("\(Int(calories.rounded())) cal")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        if !meal.tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(meal.tags, id: \.self) { tag in
                        Text(tag.replacingOccurrences(of: "-", with: " "))
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.green.opacity(0.12), in: Capsule())
                    }
                }
            }
        }

        ForEach(meal.tips, id: \.self) { TipRow(tip: .init(kind: .info, text: $0)) }
    }

    private func stat(_ label: String, _ value: Double?, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map { "\(Int($0.rounded()).formatted())\(unit)" } ?? "–")
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var slotName: String { MealSlot(for: meal.capturedAt).name.capitalized }
}

/// Breakfast / lunch / dinner / snack, from the time a meal was taken.
enum MealSlot: String, CaseIterable {
    case breakfast, lunch, dinner, snack

    init(for date: Date, calendar: Calendar = .current) {
        let hour = Double(calendar.component(.hour, from: date)) + Double(calendar.component(.minute, from: date)) / 60
        switch hour {
        case 4..<11: self = .breakfast
        case 11..<15.5: self = .lunch
        case 17..<22: self = .dinner
        default: self = .snack
        }
    }

    var name: String { rawValue }
}
