import PhotosUI
import SwiftData
import SwiftUI

/// Food › Today: calories, review queue, nutrients, tips and today's meals.
struct FoodTodayView: View {
    @Environment(GlassesController.self) private var glasses
    @Environment(MealPipeline.self) private var pipeline
    @Environment(WakeWordListener.self) private var wakeWord
    @Query(sort: \Meal.capturedAt, order: .reverse) private var meals: [Meal]
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        let goals = Goals.current
        let today = Insights.day(.now, from: meals)
        let todaysMeals = today.meals.filter { $0.status != .review }.sorted { $0.capturedAt > $1.capturedAt }
        let toReview = meals.filter { $0.status == .review }

        List {
            Section {
                summaryCard(today, goals: goals)
            }

            Section {
                logButtons
                Text(pipeline.lastStatus).font(.caption).foregroundStyle(.secondary)
            } header: {
                statusChips
            }

            if !toReview.isEmpty {
                Section {
                    ForEach(toReview) { meal in
                        NavigationLink(value: meal) { ReviewRow(meal: meal) }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task { await pipeline.send(meal) }
                                } label: {
                                    Label("Send", systemImage: "paperplane.fill")
                                }
                                .tint(.green)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    pipeline.delete(meal)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                    }
                    if toReview.count > 1 {
                        Button("Send all \(toReview.count)") {
                            Task { for meal in toReview { await pipeline.send(meal) } }
                        }
                    }
                } header: {
                    Text("To review (\(toReview.count))")
                } footer: {
                    Text("Swipe right to send for analysis, left to delete.")
                }
            }

            Section("Nutrition") {
                NutrientBar(label: "Protein", value: today.totals.proteinG, target: goals.proteinG, unit: "g")
                NutrientBar(label: "Carbs", value: today.totals.carbsG, target: goals.carbsG, unit: "g")
                NutrientBar(label: "Fat", value: today.totals.fatG, target: goals.fatG, unit: "g")
                NutrientBar(label: "Fiber", value: today.totals.fiberG, target: goals.fiberG, unit: "g")
                NutrientBar(label: "Sugar", value: today.totals.sugarG, target: goals.sugarMaxG, unit: "g", isLimit: true)
                NutrientBar(label: "Sodium", value: today.totals.sodiumMg, target: goals.sodiumMaxMg, unit: "mg", isLimit: true)
            }

            Section("Tips") {
                ForEach(Insights.tips(for: today, goals: goals)) { TipRow(tip: $0) }
            }

            Section("Meals") {
                if todaysMeals.isEmpty {
                    Text("Nothing logged yet today.").foregroundStyle(.secondary)
                }
                ForEach(todaysMeals) { meal in
                    ExpandableMealRow(meal: meal)
                }
                .onDelete { offsets in
                    offsets.map { todaysMeals[$0] }.forEach(pipeline.delete)
                }
            }
        }
        .onChange(of: pickerItem) { _, item in
            Task { await logPicked(item) }
        }
    }

    private func summaryCard(_ today: DaySummary, goals: Goals) -> some View {
        HStack(spacing: 20) {
            CalorieRing(eaten: today.totals.calories ?? 0, goal: goals.calories)
                .frame(width: 130, height: 130)
            VStack(alignment: .leading, spacing: 10) {
                let remaining = goals.calories - (today.totals.calories ?? 0)
                VStack(alignment: .leading) {
                    Text(remaining >= 0 ? "\(Int(remaining))" : "+\(Int(-remaining))")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text(remaining >= 0 ? "calories left" : "over goal")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    HealthScoreBadge(score: today.healthScore)
                    Text(today.healthScore == nil ? "No score yet" : "health score")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let split = today.macroSplit {
                    Text("P \(pct(split.protein)) · C \(pct(split.carbs)) · F \(pct(split.fat))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var logButtons: some View {
        HStack {
            Button {
                Task { await pipeline.logMealFromGlasses(trigger: "app_button") }
            } label: {
                Label("Snap with glasses", systemImage: "eyeglasses")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!glasses.isReady || pipeline.busy)

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Image(systemName: "photo.on.rectangle")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Log from photo library")
        }
    }

    private var statusChips: some View {
        HStack(spacing: 6) {
            StatusChip(systemImage: "eyeglasses",
                       text: glasses.isReady ? "Glasses" : "Glasses off",
                       ok: glasses.isReady)
            StatusChip(systemImage: "waveform",
                       text: wakeWord.isListening ? "Hey Dewin" : "Wake word off",
                       ok: wakeWord.isListening)
            StatusChip(systemImage: "antenna.radiowaves.left.and.right",
                       text: pipeline.backendConnected ? "Backend" : "Offline",
                       ok: pipeline.backendConnected)
        }
        .textCase(nil)
    }

    private func logPicked(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        pickerItem = nil
        await pipeline.logMeal(photo: data)
    }

    private func pct(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
