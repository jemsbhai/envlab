import Foundation
import Security

/// Claude reads each meal photo (Anthropic Messages API, called from the phone with the user's own key).
enum ClaudeModel: String, CaseIterable, Identifiable {
    case opus = "claude-opus-5-5", sonnet = "claude-sonnet-5-5", haiku = "claude-haiku-5-5"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .opus: "Opus 5.5 (best)"
        case .sonnet: "Sonnet 5.5 (faster)"
        case .haiku: "Haiku 5.5 (fastest)"
        }
    }
}

enum ClaudeSettings {
    static let modelKey = "claude.model"
    /// "claude" or "server": who analyzes food photos.
    static let foodAnalyzerKey = "food.analyzer"

    static var isEnabled: Bool { UserDefaults.standard.string(forKey: foodAnalyzerKey) == "claude" }

    static var model: ClaudeModel {
        ClaudeModel(rawValue: UserDefaults.standard.string(forKey: modelKey) ?? "") ?? .opus
    }

    /// The Anthropic API key, in the Keychain (service "io.occh.dewin.anthropic"). Never logged.
    static var apiKey: String { ClaudeKeychain.read() ?? "" }
    static var hasKey: Bool { !apiKey.isEmpty }
    /// Strips what a paste often brings along: spaces, newlines, quotes, invisible characters.
    static func saveKey(_ key: String) {
        let junk = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’`\u{200B}\u{FEFF}"))
        ClaudeKeychain.write(key.components(separatedBy: junk).joined())
    }

    /// "sk-ant-api03-… (108 characters)": enough to spot a wrong or truncated key, never the key.
    static var keyHint: String {
        let key = apiKey
        guard !key.isEmpty else { return "none" }
        return "\(key.prefix(13))… (\(key.count) characters)"
    }

    /// One tiny request (list models) to check the saved key. Returns Anthropic's own answer.
    static func testKey() async -> String {
        let key = apiKey
        guard !key.isEmpty else { return "No key saved." }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return "Key works." }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "no details"
            return "Anthropic said \(code): \(message)"
        } catch {
            return "Couldn't reach Anthropic: \(error.localizedDescription)"
        }
    }
}

/// Food photos only: analyzed by Claude instead of the server. The server connection (air, water,
/// report) is separate and unchanged.
@MainActor
final class ClaudeFood {
    var onEvent: ((BackendEvent) -> Void)?
    private var inFlight: Set<String> = []

    var statusText: String {
        ClaudeSettings.hasKey ? "Claude \(ClaudeSettings.model.label): reads each photo" : "Add your Anthropic API key"
    }

    /// Returns at once; the result arrives through `onEvent`, like a server's `meal:result`.
    func submit(_ meal: MealSubmit) throws {
        let apiKey = ClaudeSettings.apiKey
        guard !apiKey.isEmpty else { throw BackendError.rejected("Add your Anthropic API key in Settings › Food analysis.") }
        guard !inFlight.contains(meal.mealId) else { return }
        inFlight.insert(meal.mealId)
        let analyzer = ClaudeMealAnalyzer(apiKey: apiKey, model: ClaudeSettings.model.rawValue)
        Task { @MainActor [weak self] in
            self?.onEvent?(.status(.init(schema: "dewin.meal.status/1", mealId: meal.mealId, stage: "analyzing")))
            let result: MealResultMessage
            do {
                result = try await analyzer.analyze(meal)
            } catch {
                NSLog("[Claude] meal %@ failed: %@", meal.mealId, error.localizedDescription)
                result = MealResultMessage(schema: "dewin.meal.result/1", mealId: meal.mealId, status: "failed",
                                           processedAt: .now, error: error.localizedDescription, meal: nil)
            }
            self?.inFlight.remove(meal.mealId)
            self?.onEvent?(.result(result))
        }
    }
}

/// One Messages API call per photo, forced to answer through the `record_meal` tool.
struct ClaudeMealAnalyzer: Sendable {
    let apiKey: String
    let model: String

    enum Failure: LocalizedError {
        case http(Int, String)
        case noAnswer
        var errorDescription: String? {
            switch self {
            case let .http(401, message): "Claude rejected the API key (\(message)). Use Test key in Settings › Food analysis."
            case .http(429, _): "Claude is rate limiting. Tap Retry in a minute."
            case let .http(code, message): "Claude error \(code): \(message)"
            case .noAnswer: "Claude didn't return a meal."
            }
        }
    }

    func analyze(_ meal: MealSubmit) async throws -> MealResultMessage {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let time = meal.capturedAt.formatted(date: .omitted, time: .shortened)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "system": Self.system,
            "tools": [Self.tool],
            // Newer models reject a forced tool ("tool"/"any"); the system prompt asks for it instead.
            "tool_choice": ["type": "auto"],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                 "data": meal.jpeg.base64EncodedString()]],
                    ["type": "text", "text": "Photo taken at \(time) local time. Record this meal."],
                ],
            ]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var (data, response) = try await URLSession.shared.data(for: request)
        var code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if [429, 500, 502, 503, 529].contains(code) { // one retry when busy
            try await Task.sleep(for: .seconds(2))
            (data, response) = try await URLSession.shared.data(for: request)
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard code == 200 else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "no details"
            throw Failure.http(code, message)
        }
        let content = json["content"] as? [[String: Any]] ?? []
        let toolInput = content.first(where: { $0["type"] as? String == "tool_use" })?["input"] as? [String: Any]
        guard let input = toolInput ?? Self.jsonObject(inText: content) else { throw Failure.noAnswer }
        return Self.result(from: input, mealId: meal.mealId)
    }

    /// Fallback when the model answers in text: the first {...} object in its text blocks.
    static func jsonObject(inText content: [[String: Any]]) -> [String: Any]? {
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    static func result(from input: [String: Any], mealId: String) -> MealResultMessage {
        func number(_ object: [String: Any], _ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        guard input["isFood"] as? Bool ?? true else {
            return MealResultMessage(schema: "dewin.meal.result/1", mealId: mealId, status: "not_food",
                                     processedAt: .now, error: nil, meal: nil)
        }
        let items = (input["items"] as? [[String: Any]] ?? []).map { item in
            MealResultMessage.Item(
                name: item["name"] as? String ?? "Food",
                portion: item["portion"] as? String,
                nutrients: Nutrients(calories: number(item, "calories"), proteinG: number(item, "proteinG"),
                                     carbsG: number(item, "carbsG"), fatG: number(item, "fatG"),
                                     fiberG: number(item, "fiberG"), sugarG: number(item, "sugarG"),
                                     sodiumMg: number(item, "sodiumMg"))
            )
        }
        let totals = items.compactMap(\.nutrients).reduce(Nutrients.zero, +)
        let name = input["name"] as? String ?? "Meal"
        let calories = Int(((totals.calories ?? 0) / 10).rounded()) * 10
        let tip = input["tip"] as? String
        return MealResultMessage(
            schema: "dewin.meal.result/1", mealId: mealId, status: "analyzed", processedAt: .now, error: nil,
            meal: .init(name: name, items: items, totals: totals,
                        healthScore: number(input, "healthScore").map { min(max($0, 0), 100) },
                        tags: input["tags"] as? [String], tips: tip.map { [$0] },
                        spokenSummary: "\(name), about \(calories) calories.")
        )
    }

    static let system = """
    You are Dewin's nutrition analyst. Look at the meal photo, name each food or drink, estimate its portion \
    from visual cues (plates are about 26 cm, forks about 19 cm), and estimate nutrients for that portion using \
    USDA FoodData Central values. Be realistic, not optimistic. If the photo shows no food or drink, set isFood \
    to false. healthScore is 0–100 for how well the meal fits a balanced diet (fiber, protein, whole foods up; \
    added sugar, sodium, fried and ultra-processed down). tags are short lowercase labels such as high-protein, \
    high-fiber, high-sodium, high-sugar, refined-carbs, balanced, omega-3. tip is one short, practical sentence, \
    never a lecture. Always answer by calling the record_meal tool exactly once, with no other text.
    """

    static let tool: [String: Any] = {
        let number: [String: Any] = ["type": "number"]
        let item: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string"], "portion": ["type": "string", "description": "e.g. 150 g, 1 cup, 2 slices"],
                "calories": number, "proteinG": number, "carbsG": number, "fatG": number,
                "fiberG": number, "sugarG": number, "sodiumMg": number,
            ],
            "required": ["name", "portion", "calories", "proteinG", "carbsG", "fatG", "fiberG", "sugarG", "sodiumMg"],
        ]
        return [
            "name": "record_meal",
            "description": "Record the meal in the photo with per-item nutrition estimates.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "isFood": ["type": "boolean"],
                    "name": ["type": "string", "description": "Short meal name, e.g. Burrito bowl"],
                    "items": ["type": "array", "items": item],
                    "healthScore": ["type": "number", "description": "0 to 100"],
                    "tags": ["type": "array", "items": ["type": "string"]],
                    "tip": ["type": "string"],
                ],
                "required": ["isFood", "name", "items", "healthScore", "tags", "tip"],
            ] as [String: Any],
        ]
    }()
}

private enum ClaudeKeychain {
    static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.occh.dewin.anthropic",
        kSecAttrAccount as String: "apiKey",
    ]

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String) {
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { NSLog("[Claude] couldn't save the key to the Keychain (%d)", status) }
    }
}
