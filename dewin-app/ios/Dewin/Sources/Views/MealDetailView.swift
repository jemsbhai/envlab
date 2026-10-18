import SwiftUI
import UIKit

struct MealDetailView: View {
    @Environment(MealPipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss
    let meal: Meal

    var body: some View {
        List {
            if let photo = meal.photo, let image = UIImage(data: photo) {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets())
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meal.name ?? statusText).font(.title3.weight(.semibold))
                        Text(meal.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if meal.isPending { ProgressView() } else { HealthScoreBadge(score: meal.healthScore) }
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
                if let error = meal.errorMessage, meal.status != .analyzed {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            if meal.status == .analyzed {
                Section("Totals") {
                    row("Calories", meal.calories, "cal")
                    row("Protein", meal.proteinG, "g")
                    row("Carbs", meal.carbsG, "g")
                    row("Fat", meal.fatG, "g")
                    row("Fiber", meal.fiberG, "g")
                    row("Sugar", meal.sugarG, "g")
                    row("Sodium", meal.sodiumMg, "mg")
                }

                if !meal.items.isEmpty {
                    Section("What's in it") {
                        ForEach(meal.items, id: \.self) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                    if let portion = item.portion, !portion.isEmpty {
                                        Text(portion).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let calories = item.nutrients?.calories {
                                    Text("\(Int(calories.rounded())) cal")
                                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !meal.tips.isEmpty {
                    Section("Tips") {
                        ForEach(meal.tips, id: \.self) { TipRow(tip: .init(kind: .info, text: $0)) }
                    }
                }
            }

            Section {
                if meal.status == .review {
                    Button("Send for analysis") {
                        Task { await pipeline.send(meal) }
                    }
                }
                if meal.status == .queued || meal.status == .failed {
                    Button("Try again") { Task { await pipeline.retry(meal) } }
                }
                Button(meal.status == .review ? "Delete photo" : "Delete meal", role: .destructive) {
                    pipeline.delete(meal)
                    dismiss()
                }
            }
        }
        .navigationTitle("Meal")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusText: String {
        switch meal.status {
        case .review: "Ready to review"
        case .queued: "Waiting to send"
        case .sent, .analyzing: "Analyzing…"
        case .notFood: "Not food"
        case .failed: "Couldn't analyze"
        case .analyzed: "Meal"
        }
    }

    private func row(_ label: String, _ value: Double?, _ unit: String) -> some View {
        LabeledContent(label, value: value.map { "\(formatted($0)) \(unit)" } ?? "–")
    }

    private func formatted(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded()))" : value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
