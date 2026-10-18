import Observation
import SwiftUI

/// Which tab and section is showing. Shared so Home's cards can jump straight to
/// Food › Week or Health › Map, and so debug launch arguments can open any screen.
@Observable
@MainActor
final class Router {
    enum Tab: String, CaseIterable { case home, food, health, settings }

    enum FoodSection: String, CaseIterable, Identifiable {
        case today, week, log
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum HealthSection: String, CaseIterable, Identifiable {
        case today, week, log, map
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var tab: Tab = .home
    var food: FoodSection = .today
    var health: HealthSection = .today
    /// Set to show the 90-day report from anywhere (Home card, Health › Today card).
    var showReport = false

    func open(_ section: FoodSection) { food = section; tab = .food }
    func open(_ section: HealthSection) { health = section; tab = .health }

    init() {
        // Debug: `--tab=home|food|health|settings`, `--food=today|week|log`,
        // `--health=today|week|log|map`, `--report` (opens the 90-day report).
        let args = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            args.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        if let raw = value("tab"), let tab = Tab(rawValue: raw) { self.tab = tab }
        if let raw = value("food"), let food = FoodSection(rawValue: raw) { self.food = food; tab = .food }
        if let raw = value("health"), let health = HealthSection(rawValue: raw) { self.health = health; tab = .health }
        if args.contains("--report") { showReport = true }
    }
}
