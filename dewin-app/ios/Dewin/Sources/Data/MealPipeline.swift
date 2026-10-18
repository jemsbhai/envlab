import Foundation
import Observation
import SwiftData
import UIKit

/// The core loop: trigger → glasses photo → saved meal → backend → result → spoken summary.
@Observable
@MainActor
final class MealPipeline {
    private(set) var lastStatus = "Ready"
    private(set) var busy = false
    private(set) var backendDescription = ""
    private(set) var backendConnected = false

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let glasses: GlassesController
    @ObservationIgnored private let speaker: Speaker
    @ObservationIgnored private var backend: DewinBackend
    /// Food photos go to Claude instead of the server when Settings › Food analysis says so.
    @ObservationIgnored let claude = ClaudeFood()
    /// Runs each time the server connection comes up (the location reporter flushes on it).
    @ObservationIgnored var onBackendConnected: (() -> Void)?

    /// The one server connection, shared with the air & water side.
    var currentBackend: DewinBackend { backend }
    @ObservationIgnored private var backendSettings: BackendSettings

    init(context: ModelContext, glasses: GlassesController, speaker: Speaker) {
        self.context = context
        self.glasses = glasses
        self.speaker = speaker
        backendSettings = .current
        backend = Self.makeBackend(backendSettings)
        attach(backend)
        backend.start()
        claude.onEvent = { [weak self] event in self?.handle(event) }
        if ClaudeSettings.isEnabled { Task { await resubmitQueued() } }
        glasses.onTrigger = { [weak self] in
            Task { await self?.logMealFromGlasses(trigger: "capture_button") }
        }
    }

    // MARK: Logging

    /// Takes a photo through the glasses and sends it straight to analysis (Claude or the server).
    func logMealFromGlasses(trigger: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            speaker.cue(.capturing)
            lastStatus = "Taking photo…"
            let jpeg = try await glasses.capturePhoto()
            let meal = Meal(photo: jpeg, source: "glasses", trigger: trigger)
            context.insert(meal)
            try? context.save()
            NSLog("[Pipeline] %@ captured, sending", meal.id.uuidString)
            speaker.say("Got it.")
            await submit(meal)
        } catch {
            lastStatus = error.localizedDescription
            speaker.cue(.failed)
            speaker.say("Sorry, I couldn't take the photo.")
        }
    }

    /// Logs a photo picked on the phone (also handy for testing without glasses).
    func logMeal(photo: Data, capturedAt: Date = .now) async {
        let meal = Meal(photo: photo, source: "photo_library", trigger: "photo_library", capturedAt: capturedAt)
        context.insert(meal)
        try? context.save()
        await submit(meal)
    }

    /// Approves a reviewed photo: sends it for analysis.
    func send(_ meal: Meal) async {
        guard meal.status == .review else { return }
        meal.status = .queued
        try? context.save()
        await submit(meal)
    }

    func retry(_ meal: Meal) async {
        meal.status = .queued
        meal.errorMessage = nil
        await submit(meal)
    }

    func delete(_ meal: Meal) {
        context.delete(meal)
        try? context.save()
    }

    // MARK: Questions

    /// "Hey Dewin, how many calories did I eat today?" Answered on the phone from the log, then spoken.
    @discardableResult
    func answer(question: String) -> String {
        let since = Calendar.current.date(byAdding: .day, value: -8, to: .now) ?? .distantPast
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.capturedAt >= since })
        let meals = (try? context.fetch(descriptor)) ?? []
        let reply = MealQA.answer(question, meals: meals, goals: .current)
        NSLog("[Pipeline] Q: %@ → A: %@", question, reply)
        lastStatus = reply
        speaker.say(reply)
        return reply
    }

    // MARK: Backend

    func applySettings(_ settings: BackendSettings) {
        guard settings != backendSettings else { return }
        backendSettings = settings
        backend.stop()
        backend = Self.makeBackend(settings)
        attach(backend)
        backend.start()
        refreshBackendStatus()
    }

    /// Reconnects with fresh settings and client ID (after "Delete my data").
    func restartBackend() {
        backendSettings = .current
        backend.stop()
        backend = Self.makeBackend(backendSettings)
        attach(backend)
        backend.start()
        refreshBackendStatus()
    }

    /// Food analysis switched or got a key: send meals that were waiting.
    func foodAnalysisChanged() {
        Task { await resubmitQueued() }
    }

    private static func makeBackend(_ settings: BackendSettings) -> DewinBackend {
        if settings.mode == .socket, let socket = SocketIOBackend(settings: settings, clientID: BackendSettings.clientID) {
            return socket
        }
        return MockBackend()
    }

    private func attach(_ backend: DewinBackend) {
        backend.onEvent = { [weak self] event in self?.handle(event) }
        backend.onConnectionChange = { [weak self] in
            self?.refreshBackendStatus()
            if self?.backend.isConnected == true {
                Task { await self?.resubmitQueued() }
                self?.onBackendConnected?()
            }
        }
        refreshBackendStatus()
    }

    private func refreshBackendStatus() {
        backendDescription = backend.connectionDescription
        backendConnected = backend.isConnected
    }

    private func submit(_ meal: Meal) async {
        guard let photo = meal.photo, let image = ImagePrep.forUpload(photo) else {
            meal.status = .failed
            meal.errorMessage = "The photo couldn't be prepared for upload."
            try? context.save()
            return
        }
        let message = MealSubmit(
            mealId: meal.id.uuidString.lowercased(),
            clientId: BackendSettings.clientID,
            capturedAt: meal.capturedAt,
            timezone: TimeZone.current.identifier,
            source: meal.source,
            trigger: meal.trigger,
            jpeg: image.jpeg,
            width: image.width,
            height: image.height
        )
        lastStatus = "Sending…"
        do {
            if ClaudeSettings.isEnabled { try claude.submit(message) } else { try await backend.submit(message) }
            meal.status = .sent
            meal.sentAt = .now
            lastStatus = "Analyzing…"
        } catch {
            // Stays queued; resent automatically when the backend reconnects.
            meal.status = .queued
            meal.errorMessage = error.localizedDescription
            lastStatus = "Saved. Will send when connected."
        }
        try? context.save()
    }

    private func resubmitQueued() async {
        let queued = Meal.Status.queued.rawValue
        let descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.statusRaw == queued })
        for meal in (try? context.fetch(descriptor)) ?? [] {
            await submit(meal)
        }
    }

    private func handle(_ event: BackendEvent) {
        switch event {
        case let .status(status):
            guard let meal = meal(id: status.mealId), meal.isPending else { return }
            meal.status = .analyzing
            try? context.save()
        case let .result(result):
            guard let meal = meal(id: result.mealId) else {
                NSLog("[Pipeline] result for unknown meal %@", result.mealId)
                return
            }
            let wasPending = meal.isPending
            meal.apply(result)
            try? context.save()
            NSLog("[Pipeline] %@ → %@ %@", result.mealId, meal.statusRaw, meal.name ?? "")
            guard wasPending else { return }
            lastStatus = meal.name.map { "Logged \($0)" } ?? "Done"
            // Only speak results for meals logged in the last few minutes, not a backlog.
            if Date().timeIntervalSince(meal.sentAt ?? meal.capturedAt) < 300 {
                speaker.say(spokenSummary(for: meal, result: result))
            }
        }
    }

    private func spokenSummary(for meal: Meal, result: MealResultMessage) -> String {
        switch meal.status {
        case .notFood: return "That doesn't look like food, so I didn't log it."
        case .failed: return "Sorry, I couldn't analyze that meal."
        default: break
        }
        if let summary = result.meal?.spokenSummary, !summary.isEmpty { return summary }
        let name = meal.name ?? "Meal"
        guard let calories = meal.calories else { return "\(name) logged." }
        return "\(name), about \(Int(calories.rounded())) calories."
    }

    private func meal(id: String) -> Meal? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        var descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// Keeps uploads well under the server's max_payload (see BACKEND_CONTRACT.md).
enum ImagePrep {
    static let maxSide: CGFloat = 1280
    static let maxBytes = 1_500_000

    static func forUpload(_ data: Data) -> (jpeg: Data, width: Int, height: Int)? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.7, 0.55, 0.4, 0.3] {
            if let jpeg = resized.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
                return (jpeg, Int(size.width), Int(size.height))
            }
        }
        return nil
    }
}
