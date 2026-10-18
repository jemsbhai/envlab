import Foundation

/// The report from the design mockup, with dates moved to the last 90 days, so the screen can be
/// built and reviewed before the server computes real reports.
enum MockReport {
    static func sample(days: Int = 90, now: Date = .now, calendar: Calendar = .current) -> ExposureReport {
        let to = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -(days - 1), to: to) ?? to
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: from) ?? from }

        // Spikes at roughly the same places in the range as the mockup (Mar 14, Apr 2, May 9 of Mar 1–May 29).
        let smoke = 13, bus = 32, cloudy = 69
        let badAir: Set<Int> = [3, 9, smoke, smoke + 1, 21, bus, 38, 44, 51, 57, 63, 72, 78, 85]       // 14 days
        let badWater: Set<Int> = [cloudy, 74]                                                          // 2 days
        let neutral: Set<Int> = [1, 5, 7, 11, 17, 19, 24, 27, 30, 35, 41, 47, 49, 54, 60, 66, 70, 76, 81, 83, 88]
        let gaps: Set<Int> = [25, 26, 46, 64, 65, 87] // phone off or no sensor nearby

        let timeline = (0..<days).map { offset -> ExposureReport.TimelineDay in
            let level: ReportLevel = badAir.contains(offset) || badWater.contains(offset) ? .bad
                : neutral.contains(offset) ? .neutral : .good
            return .init(date: day(offset), level: gaps.contains(offset) ? .neutral : level, hasData: !gaps.contains(offset))
        }

        return ExposureReport(
            schema: ExposureReport.schema,
            days: days, from: from, to: to,
            score: 64,
            summary: "Your air was worse than 68% of your city. Your water was clean.",
            previousScore: 70,
            scoreMethod: "The share of your measured hours under the safe limits for air, water and indoor CO₂, weighted by how long you spent in each place. Days with no data don't count either way.",
            comparisonSource: "City comparison uses EPA AirNow monitors in your area, not other Dewin users.",
            overLimit: [
                .init(key: "air", label: "Air", days: badAir.count, level: .bad, estimated: true),
                .init(key: "water", label: "Water", days: badWater.count, level: .good, estimated: false),
                .init(key: "co2Indoor", label: "CO₂ indoors", days: 31, level: .bad, estimated: false),
            ],
            timeline: timeline,
            spikes: [
                .init(date: day(smoke), label: "smoke"),
                .init(date: day(bus), label: "bus loop"),
                .init(date: day(cloudy), label: "cloudy tap"),
            ],
            places: [
                .init(id: "commute", name: "Commute (Route 12 bus)", level: .bad, share: 1.0,
                      note: "worst 30 min of your day", verified: false),
                .init(id: "school", name: "Lincoln Elementary pickup", level: .bad, share: 0.82,
                      note: "8:05–8:20am spike", verified: false),
                .init(id: "office", name: "Office", level: .neutral, share: 0.55, note: "CO₂ high after 2pm", verified: false),
                .init(id: "home", name: "Home", level: .good, share: 0.22, note: "tap verified by your Dewin", verified: true),
                .init(id: "cafe", name: "Lucy's Café", level: .good, share: 0.15, note: "Dewin Verified", verified: true),
            ],
            exposures: [
                .init(key: "pm25", label: "Fine particles (PM2.5)", unit: "µg/m³", average: 11.4, limit: "≤ 9",
                      worst: 87, worstDate: day(smoke), withinLimit: false, estimated: true),
                .init(key: "voc", label: "Fumes (VOCs)", unit: "ppb", average: 210, limit: "≤ 500",
                      worst: 1_340, worstDate: day(bus), withinLimit: true, estimated: false),
                .init(key: "co2", label: "CO₂ (indoors)", unit: "ppm", average: 870, limit: "≤ 1,000",
                      worst: 2_150, worstDate: day(58), withinLimit: true, estimated: false),
                .init(key: "ph", label: "Water pH", unit: "", average: 7.3, limit: "6.5–8.5",
                      worst: 8.7, worstDate: day(cloudy), withinLimit: true, estimated: false),
                .init(key: "turbidity", label: "Water cloudiness", unit: "NTU", average: 0.4, limit: "≤ 1",
                      worst: 4.2, worstDate: day(cloudy), withinLimit: true, estimated: false),
            ],
            body: .init(device: "Apple Watch", highAirDays: badAir.count, restingHeartRateDelta: 6,
                        sleepScoreDelta: -11, symptom: "cough", symptomDays: 5),
            actions: [
                .init(id: "commute", source: "Commute", level: .bad,
                      text: "Ride before 8am. Readings on your bus are 40% lower then."),
                .init(id: "school", source: "School pickup", level: .bad,
                      text: "Wait 50 m from the pickup loop. The spike lasts 12 min."),
                .init(id: "office", source: "Office", level: .neutral,
                      text: "Open a window after 2pm, or ask facilities about ventilation."),
                .init(id: "water", source: "Home water (the 2 days)", level: .neutral,
                      text: "Cloudy tap? Run it 2 minutes first."),
                .init(id: "smoke", source: "Wildfire day", level: .bad,
                      text: "Smoke day? Run a HEPA purifier in the bedroom."),
            ],
            sources: .init(
                text: "Sources: your Dewin home unit, 11 Dewin sensors you visited, EPA AirNow, your city water utility.",
                estimatedNote: "Readings labeled 'estimated' came from public data, not a Dewin sensor."
            )
        )
    }
}
