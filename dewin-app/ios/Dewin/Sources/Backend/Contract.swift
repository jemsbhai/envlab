import Foundation

// Wire types for docs/BACKEND_CONTRACT.md. Keep the two in sync.

struct Nutrients: Codable, Hashable, Sendable {
    var calories: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var fiberG: Double?
    var sugarG: Double?
    var sodiumMg: Double?

    static let zero = Nutrients(calories: 0, proteinG: 0, carbsG: 0, fatG: 0, fiberG: 0, sugarG: 0, sodiumMg: 0)

    /// Sums known values; unknown stays unknown only if every input is unknown.
    static func + (a: Nutrients, b: Nutrients) -> Nutrients {
        func add(_ x: Double?, _ y: Double?) -> Double? {
            x == nil && y == nil ? nil : (x ?? 0) + (y ?? 0)
        }
        return Nutrients(
            calories: add(a.calories, b.calories), proteinG: add(a.proteinG, b.proteinG),
            carbsG: add(a.carbsG, b.carbsG), fatG: add(a.fatG, b.fatG),
            fiberG: add(a.fiberG, b.fiberG), sugarG: add(a.sugarG, b.sugarG),
            sodiumMg: add(a.sodiumMg, b.sodiumMg)
        )
    }
}

/// One meal photo going to the server: the `meal:submit` event. JSON fields plus the JPEG
/// as a Socket.IO binary attachment (see BACKEND_CONTRACT.md).
struct MealSubmit: @unchecked Sendable {
    static let schema = "dewin.meal.submit/1"

    var mealId: String
    var clientId: String
    var capturedAt: Date
    var timezone: String
    var source: String
    var trigger: String
    var jpeg: Data
    var width: Int
    var height: Int

    /// The event payload, in contract order. `image` stays `Data`, so Socket.IO sends it as binary.
    var payload: [String: Any] {
        [
            "schema": Self.schema,
            "mealId": mealId,
            "clientId": clientId,
            "capturedAt": ContractCoding.isoString(capturedAt),
            "timezone": timezone,
            "source": source,
            "trigger": trigger,
            "contentType": "image/jpeg",
            "width": width,
            "height": height,
            "image": jpeg,
        ]
    }
}

struct MealStatusMessage: Codable, Sendable {
    var schema: String?
    var mealId: String
    var stage: String
}

struct MealResultMessage: Codable, Sendable {
    struct Item: Codable, Hashable, Sendable {
        var name: String
        var portion: String?
        var nutrients: Nutrients?
    }

    struct Meal: Codable, Sendable {
        var name: String
        var items: [Item]?
        var totals: Nutrients?
        var healthScore: Double?
        var tags: [String]?
        var tips: [String]?
        var spokenSummary: String?
    }

    var schema: String?
    var mealId: String
    var status: String
    var processedAt: Date?
    var error: String?
    var meal: Meal?
}

enum ContractCoding {
    static func isoString(_ date: Date) -> String { isoFormatter.string(from: date) }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoString(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = isoFormatter.date(from: string) ?? isoFractional.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(string)"))
        }
        return decoder
    }()

    /// ISO 8601 with the local UTC offset, e.g. 2026-10-18T12:31:05-04:00.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
