import Foundation
import SwiftUI

// The 90-day "How you dewin?" report. Consumer API: the app emits `report:get` and the server
// answers in the ack with an `ExposureReport`. See docs/BACKEND_CONTRACT.md, "90-day report".

struct ReportRequest: Codable, Sendable {
    static let event = "report:get"
    static let schema = "dewin.report.get/1"
    var schema = ReportRequest.schema
    var clientId: String
    var days: Int
    var timezone: String
}

/// good = aqua, neutral = gray, bad = orange. The whole report uses only these three.
enum ReportLevel: String, Codable, Sendable {
    case good, neutral, bad

    var color: Color {
        switch self {
        case .good: Brand.aqua
        case .neutral: Brand.gray
        case .bad: Brand.orange
        }
    }

    var label: String {
        switch self {
        case .good: "Clean"
        case .neutral: "Mixed"
        case .bad: "Over the limit"
        }
    }
}

struct ExposureReport: Codable, Sendable {
    static let schema = "dewin.report/1"

    var schema: String?
    var days: Int
    var from: Date
    var to: Date
    /// 0–100, higher is better. Shown aqua at 70 and up, orange below.
    var score: Int
    /// One plain sentence under the score, e.g. "Your air was worse than 68% of your city. Your water was clean."
    var summary: String
    /// The score for the 90 days before this period, for the trend ("↓ 6 vs previous 90 days").
    var previousScore: Int?
    /// How the score is calculated, in one or two plain sentences ("How this is scored").
    var scoreMethod: String?
    /// Where the city comparison comes from, e.g. "Compared with EPA AirNow monitors in your city."
    var comparisonSource: String?
    /// Usually Air, Water, CO2 indoors. The row a doctor reads first.
    var overLimit: [OverLimit]
    /// One entry per day, oldest first (`days` entries).
    var timeline: [TimelineDay]
    /// Three or four labeled spikes on the timeline.
    var spikes: [Spike]
    /// Ranked worst first.
    var places: [Place]
    /// The only section with real units; for the doctor.
    var exposures: [Exposure]
    /// Present only when a wearable is connected.
    var body: BodySignals?
    /// One action per finding.
    var actions: [Action]
    var sources: Sources

    struct OverLimit: Codable, Sendable, Identifiable, Hashable {
        var key: String       // "air" | "water" | "co2Indoor" | …
        var label: String     // "Air"
        var days: Int         // 14
        var level: ReportLevel
        /// Some of these days came from public data, not a Dewin sensor.
        var estimated: Bool?
        var id: String { key }
    }

    struct TimelineDay: Codable, Sendable, Identifiable, Hashable {
        var date: Date
        var level: ReportLevel
        /// False when nothing was measured that day (phone off, no sensors nearby). A gap is not "clean".
        var hasData: Bool?
        var id: Date { date }
        var isGap: Bool { hasData == false }
    }

    struct Spike: Codable, Sendable, Identifiable, Hashable {
        var date: Date
        /// "wildfire smoke", "school bus loop, 8am"
        var label: String
        var id: Date { date }
    }

    struct Place: Codable, Sendable, Identifiable, Hashable {
        var id: String
        /// "Commute (Route 12 bus)"
        var name: String
        var level: ReportLevel
        /// 0–1: how bad, for the bar length. Worst place is 1.
        var share: Double
        /// "worst 30 min of your day", "CO2 high after 2pm". Optional.
        var note: String?
        /// Measured by a Dewin sensor (home unit or a Dewin Verified place), not estimated.
        var verified: Bool
    }

    struct Exposure: Codable, Sendable, Identifiable, Hashable {
        var key: String       // "pm25" | "voc" | "co2" | "ph" | "turbidity"
        var label: String     // "Fine particles (PM2.5)"
        var unit: String      // "µg/m³"
        var average: Double
        /// "≤ 9", "6.5–8.5": shown as text because some limits are ranges.
        var limit: String
        var worst: Double
        var worstDate: Date?
        /// Whether the 90-day average is within the limit.
        var withinLimit: Bool
        /// Came from public data, not a Dewin sensor.
        var estimated: Bool?
        var id: String { key }
    }

    struct BodySignals: Codable, Sendable, Hashable {
        /// "Apple Watch", "Oura"
        var device: String?
        /// Days counted as high-air days (matches `overLimit` air).
        var highAirDays: Int
        var restingHeartRateDelta: Double?   // +6 bpm
        var sleepScoreDelta: Double?         // -11 points
        /// Symptom the person logged, and on how many of the high-air days.
        var symptom: String?
        var symptomDays: Int?
    }

    struct Action: Codable, Sendable, Identifiable, Hashable {
        var id: String
        /// What it's about: "Commute", "School pickup", "Home water"
        var source: String
        var level: ReportLevel
        var text: String
    }

    struct Sources: Codable, Sendable, Hashable {
        /// "Sources: your Dewin home unit, 11 Dewin sensors you visited, EPA AirNow, NYC water utility."
        var text: String
        /// "Readings labeled 'estimated' came from public data, not a Dewin sensor."
        var estimatedNote: String
    }
}

extension ExposureReport {
    /// "Mar 1 – May 29"
    var rangeLabel: String {
        "\(from.formatted(.dateTime.month(.abbreviated).day())) – \(to.formatted(.dateTime.month(.abbreviated).day()))"
    }

    var scoreLevel: ReportLevel { score >= 70 ? .good : .bad }

    /// Change vs the previous period; positive is better.
    var scoreChange: Int? { previousScore.map { score - $0 } }

    var gapDays: Int { timeline.filter(\.isGap).count }

    /// "On high-air days your resting heart rate was +6 bpm and your sleep score dropped 11 points.
    /// You logged 'cough' on 5 of those 14 days."
    var bodySentence: String? {
        guard let body else { return nil }
        var parts: [String] = []
        if let hr = body.restingHeartRateDelta {
            parts.append("your resting heart rate was \(hr >= 0 ? "+" : "−")\(Int(abs(hr).rounded())) bpm")
        }
        if let sleep = body.sleepScoreDelta {
            parts.append(sleep < 0 ? "your sleep score dropped \(Int(abs(sleep).rounded())) points"
                                   : "your sleep score rose \(Int(sleep.rounded())) points")
        }
        var sentence = parts.isEmpty ? "" : "On high-air days " + parts.joined(separator: " and ") + "."
        if let symptom = body.symptom, let days = body.symptomDays {
            sentence += (sentence.isEmpty ? "" : " ") + "You logged '\(symptom)' on \(days) of those \(body.highAirDays) days."
        }
        return sentence.isEmpty ? nil : sentence
    }
}
