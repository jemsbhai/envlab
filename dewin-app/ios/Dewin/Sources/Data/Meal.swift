import Foundation
import SwiftData

/// One logged meal: the photo, where it is in the pipeline, and (once analyzed) its nutrition.
@Model
final class Meal {
    enum Status: String, Codable {
        /// Taken with the glasses, kept on the phone until the user sends or deletes it.
        case review
        /// Saved, not yet accepted by the backend (offline, or the publish failed).
        case queued
        /// Backend acknowledged it; waiting for the result.
        case sent
        /// Backend reported it's working on it.
        case analyzing
        case analyzed
        case notFood
        case failed
    }

    @Attribute(.unique) var id: UUID
    var capturedAt: Date
    @Attribute(.externalStorage) var photo: Data?
    var source: String
    var trigger: String
    var statusRaw: String
    var errorMessage: String?
    var sentAt: Date?
    var analyzedAt: Date?

    var name: String?
    var calories: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var fiberG: Double?
    var sugarG: Double?
    var sodiumMg: Double?
    var healthScore: Double?
    var tags: [String] = []
    var tips: [String] = []
    var itemsData: Data?

    init(photo: Data?, source: String, trigger: String, capturedAt: Date = .now) {
        id = UUID()
        self.capturedAt = capturedAt
        self.photo = photo
        self.source = source
        self.trigger = trigger
        statusRaw = Status.queued.rawValue
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    var isPending: Bool { [.queued, .sent, .analyzing].contains(status) }

    var nutrients: Nutrients {
        Nutrients(calories: calories, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                  fiberG: fiberG, sugarG: sugarG, sodiumMg: sodiumMg)
    }

    var items: [MealResultMessage.Item] {
        guard let itemsData else { return [] }
        return (try? JSONDecoder().decode([MealResultMessage.Item].self, from: itemsData)) ?? []
    }

    /// Fills in the analysis from the backend's result message.
    func apply(_ result: MealResultMessage) {
        analyzedAt = result.processedAt ?? .now
        errorMessage = result.error
        switch result.status {
        case "analyzed":
            status = .analyzed
        case "not_food":
            status = .notFood
        default:
            status = .failed
        }
        guard let meal = result.meal else { return }
        name = meal.name
        let totals = meal.totals ?? (meal.items ?? []).compactMap(\.nutrients).reduce(.zero, +)
        calories = totals.calories
        proteinG = totals.proteinG
        carbsG = totals.carbsG
        fatG = totals.fatG
        fiberG = totals.fiberG
        sugarG = totals.sugarG
        sodiumMg = totals.sodiumMg
        healthScore = meal.healthScore
        tags = meal.tags ?? []
        tips = meal.tips ?? []
        itemsData = try? JSONEncoder().encode(meal.items ?? [])
    }
}
