import SwiftUI
import UIKit

/// Ring showing calories eaten against the daily goal.
struct CalorieRing: View {
    let eaten: Double
    let goal: Double

    private var progress: Double { goal > 0 ? eaten / goal : 0 }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 14)
            Circle()
                .trim(from: 0, to: min(progress, 1))
                .stroke(progress > 1.1 ? Color.orange : Color.green,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: progress)
            VStack(spacing: 2) {
                Text("\(Int(eaten))")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Text("of \(Int(goal)) cal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(eaten)) of \(Int(goal)) calories")
    }
}

/// One nutrient against its target. `isLimit` flips the colors: going over is the bad direction.
struct NutrientBar: View {
    let label: String
    let value: Double?
    let target: Double
    let unit: String
    var isLimit = false

    private var fraction: Double { target > 0 ? (value ?? 0) / target : 0 }

    private var color: Color {
        if isLimit { return fraction > 1 ? .red : fraction > 0.8 ? .orange : .green }
        return fraction > 1.2 ? .orange : fraction >= 1 ? .green : .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(value.map { "\(Int($0.rounded()).formatted()) / \(Int(target).formatted()) \(unit)" } ?? "–")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(fraction, 1))
                .tint(color)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HealthScoreBadge: View {
    let score: Double?

    var body: some View {
        if let score {
            Text("\(Int(score.rounded()))")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 34, minHeight: 26)
                .background(Self.color(for: score), in: Capsule())
                .accessibilityLabel("Health score \(Int(score))")
        }
    }

    static func color(for score: Double) -> Color {
        score >= 75 ? .green : score >= 50 ? .yellow : score >= 35 ? .orange : .red
    }
}

struct TipRow: View {
    let tip: Insights.Tip

    var body: some View {
        Label {
            Text(tip.text).font(.subheadline)
        } icon: {
            switch tip.kind {
            case .good: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .info: Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
            }
        }
    }
}

struct MealThumbnail: View {
    let photo: Data?
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let photo, let image = UIImage(data: photo) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "fork.knife")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MealRow: View {
    let meal: Meal

    var body: some View {
        HStack(spacing: 12) {
            MealThumbnail(photo: meal.photo)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if meal.isPending {
                ProgressView()
            } else {
                HealthScoreBadge(score: meal.healthScore)
            }
        }
    }

    private var title: String {
        switch meal.status {
        case .review: "Ready to review"
        case .queued: "Waiting to send"
        case .sent, .analyzing: "Analyzing…"
        case .notFood: "Not food"
        case .failed: "Couldn't analyze"
        case .analyzed: meal.name ?? "Meal"
        }
    }

    private var subtitle: String {
        let time = meal.capturedAt.formatted(date: .omitted, time: .shortened)
        guard let calories = meal.calories else { return time }
        return "\(time) · \(Int(calories.rounded())) cal"
    }
}

/// A glasses photo waiting for the user to send or delete it: big enough to recognize the plate.
struct ReviewRow: View {
    let meal: Meal

    var body: some View {
        HStack(spacing: 12) {
            MealThumbnail(photo: meal.photo, size: 72)
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.capturedAt.formatted(date: .omitted, time: .shortened)).font(.headline)
                Text(meal.capturedAt.formatted(.relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Small status pill for the glasses / backend / wake word.
struct StatusChip: View {
    let systemImage: String
    let text: String
    let ok: Bool

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((ok ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
            .foregroundStyle(ok ? Color.green : Color.secondary)
    }
}
