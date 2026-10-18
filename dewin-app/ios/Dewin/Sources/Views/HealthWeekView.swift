import Charts
import SwiftUI
import UIKit

/// Health › Week: your area's air and water over the last 7 days. Daily air quality, the cleanest
/// time to be outside, weekly pollutant averages, water, and a few actions from the data.
struct HealthWeekView: View {
    @Environment(NearbyHealthStore.self) private var nearby
    @Environment(LocationReporter.self) private var location
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL

    /// `days(...)` walks every station for every hour, so the week is rebuilt only when new data lands.
    @State private var week: HealthWeekData?

    var body: some View {
        Group {
            if !location.isAuthorized {
                noPermission
            } else if nearby.series == nil {
                if let error = nearby.error, !nearby.isLoading { loadFailed(error) } else { loading }
            } else if let week {
                if week.airStations == 0, week.waterStations == 0 {
                    noStations
                } else {
                    content(week)
                }
            } else {
                loading
            }
        }
        .task(id: nearby.lastLoaded) { week = nearby.series == nil ? nil : HealthWeekData(nearby: nearby) }
    }

    // MARK: Content

    private func content(_ week: HealthWeekData) -> some View {
        List {
            if let error = nearby.error {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Couldn't refresh. Showing the last readings.").font(.subheadline)
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            if week.airStations == 0 {
                Section("Air quality") {
                    HealthWeekEmptyRow(systemImage: "aqi.medium", text: "No air sensors within 15 km of you.")
                }
            } else if let air = week.air {
                airSection(week, scale: air)
                bestTimeSection(week, scale: air)
                pollutantsSection(week)
            } else {
                Section("Air quality") {
                    HealthWeekEmptyRow(systemImage: "aqi.medium", text: "Nearby sensors don't measure air quality.")
                }
            }

            waterSection(week)

            Section {
                ForEach(week.tips) { TipRow(tip: $0) }
            } header: {
                Text("Tips")
            } footer: {
                Text(week.sourceLine)
            }

            Section {
                Button {
                    router.showReport = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your 90-day report").font(.headline)
                            Text("Days over the limit, your places, what to do. Ready for your doctor.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens your 90-day exposure report")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await reload() }
    }

    // MARK: 1. Air quality

    private func airSection(_ week: HealthWeekData, scale: HealthWeekScale) -> some View {
        let metric = scale.metric
        return Section {
            if week.airDays.isEmpty {
                HealthWeekEmptyRow(systemImage: "clock", text: "No air readings this week yet. Pull down to refresh.")
            } else {
                Chart {
                    ForEach(week.airDays) { day in
                        if let average = day.average, let worst = day.worst {
                            BarMark(
                                x: .value("Day", day.day, unit: .day),
                                y: .value("Daily average", average),
                                width: .ratio(0.55)
                            )
                            .foregroundStyle(metric.level(average).color.gradient)
                            .cornerRadius(4)
                            .accessibilityLabel(day.day.formatted(.dateTime.weekday(.wide)))
                            .accessibilityValue(
                                "Average \(scale.valueText(average)), \(scale.word(metric.level(average))). "
                                    + "Worst hour \(HealthWeekWindow.hourText(Calendar.current.component(.hour, from: worst.time))), "
                                    + "\(scale.valueText(worst.value))."
                            )

                            // A whisker from the average up to the day's worst hour.
                            RuleMark(
                                x: .value("Day", day.day, unit: .day),
                                yStart: .value("Daily average", average),
                                yEnd: .value("Worst hour", worst.value)
                            )
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .accessibilityHidden(true)

                            PointMark(x: .value("Day", day.day, unit: .day), y: .value("Worst hour", worst.value))
                                .symbol { HealthWeekDot(color: metric.level(worst.value).color) }
                                .accessibilityHidden(true)
                        }
                    }
                    ForEach(scale.goodLines, id: \.self) { line in
                        RuleMark(y: .value("Good", line))
                            .foregroundStyle(Color.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .accessibilityHidden(true)
                    }
                }
                .chartXScale(domain: week.weekDomain)
                .chartYScale(domain: week.airDomain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) {
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                }
                // "Good" sits in the axis, outside the plot, so it never hides the top of a bar.
                .chartYAxis { healthWeekYAxis(goodAt: scale.labelValue) }
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .frame(height: 180)
                .padding(.top, 6)
                .accessibilityLabel("\(metric.plainName) by day")

                HealthWeekLegendRow {
                    HealthWeekLegend(text: "Daily average") {
                        RoundedRectangle(cornerRadius: 2).fill(.secondary).frame(width: 10, height: 10)
                    }
                    HealthWeekLegend(text: "Worst hour") { HealthWeekDot(color: .secondary) }
                }
                .padding(.bottom, 2)
                .accessibilityHidden(true)

                LabeledContent("Good days", value: "\(week.goodDays) of \(week.airDays.count)")
                LabeledContent("Hours over good", value: week.hoursOverGood == 1 ? "1 hour" : "\(week.hoursOverGood) hours")
                if let worst = week.worstMoment {
                    let level = metric.level(worst.value)
                    let text = "\(HealthWeekWindow.momentText(worst.time)) · \(scale.valueText(worst.value))"
                    LabeledContent("Worst moment") {
                        HealthWeekLevelValue(text: text, word: scale.word(level), color: level.color)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Worst moment")
                    .accessibilityValue("\(text), \(scale.word(level))")
                }
            }
        } header: {
            Text("Air quality")
        } footer: {
            Text(scale.footer)
        }
    }

    // MARK: 2. Best time to be outside

    private func bestTimeSection(_ week: HealthWeekData, scale: HealthWeekScale) -> some View {
        Section {
            if let clean = week.cleanest, let dirty = week.dirtiest {
                Chart {
                    ForEach(week.hourProfile) { hour in
                        let bar = RectangleMark(
                            xStart: .value("From", Double(hour.hour) + 0.12),
                            xEnd: .value("To", Double(hour.hour) + 0.88),
                            yStart: .value("Zero", 0),
                            yEnd: .value("Average", hour.average)
                        )
                        .foregroundStyle(clean.contains(hour.hour) ? Color.accentColor
                            : dirty.contains(hour.hour) ? Brand.orange : Brand.gray.opacity(0.35))
                        .cornerRadius(2)

                        if hour.hour == clean.start {
                            bar.annotation(position: .top, alignment: .leading, spacing: 4) {
                                Text("Cleanest").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                            }
                        } else if hour.hour == dirty.start {
                            bar.annotation(position: .top, alignment: .leading, spacing: 4) {
                                Text("Dirtiest").font(.caption2.weight(.semibold)).foregroundStyle(Brand.orange)
                            }
                        } else {
                            bar
                        }
                    }
                }
                .chartXScale(domain: 0...24)
                .chartYScale(domain: 0...week.hourChartMax)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let hour = value.as(Int.self) { Text(HealthWeekWindow.hourText(hour)) }
                        }
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .frame(height: 110)
                .padding(.top, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Average \(scale.metric.plainName.lowercased()) by hour of day")
                .accessibilityValue("Cleanest \(clean.rangeText), dirtiest \(dirty.rangeText)")

                LabeledContent("Cleanest air", value: "\(clean.rangeText) · \(scale.valueText(clean.average))")
                LabeledContent("Dirtiest air", value: "\(dirty.rangeText) · \(scale.valueText(dirty.average))")

                Label {
                    Text(week.bestTimeAction(scale: scale, clean: clean, dirty: dirty)).font(.subheadline.weight(.medium))
                } icon: {
                    Image(systemName: "figure.run").foregroundStyle(Color.accentColor)
                }
            } else {
                HealthWeekEmptyRow(systemImage: "clock",
                                   text: "A few more days of readings and Dewin can show your cleanest hours.")
            }
        } header: {
            Text("Best time to be outside")
        } footer: {
            if week.cleanest != nil {
                Text("Average by hour across the week, between \(HealthWeekWindow.hourText(5)) and \(HealthWeekWindow.hourText(22)).")
            }
        }
    }

    // MARK: 3. Pollutants

    private func pollutantsSection(_ week: HealthWeekData) -> some View {
        Section("Pollutants (weekly average)") {
            ForEach(week.pollutants) { pollutant in
                HealthWeekPollutantRow(pollutant: pollutant)
            }
        }
    }

    // MARK: 4. Water

    private func waterSection(_ week: HealthWeekData) -> some View {
        Section {
            if week.waterStations == 0 {
                HealthWeekEmptyRow(systemImage: "drop", text: "No water sensors within 15 km of you.")
            } else if let scale = week.water {
                if week.waterDays.isEmpty {
                    HealthWeekEmptyRow(systemImage: "clock", text: "No water readings this week yet. Pull down to refresh.")
                } else {
                    waterChart(week, scale: scale)

                    if let average = week.waterAverage {
                        let level = scale.metric.level(average)
                        LabeledContent(scale.metric == .wqi ? "Average quality" : "Weekly average") {
                            HealthWeekLevelValue(text: scale.valueText(average), word: scale.word(level), color: level.color)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(scale.metric == .wqi ? "Average water quality" : "Weekly average \(scale.metric.plainName.lowercased())")
                        .accessibilityValue("\(scale.valueText(average)), \(scale.word(level))")
                    }
                }
                // Cloudiness is shown whenever it's measured, even when the chart is the quality index.
                if !week.turbidityDays.isEmpty {
                    LabeledContent("Cloudy days", value: "\(week.cloudyDays) of \(week.turbidityDays.count)")
                }
                if let cloudiest = week.cloudiest {
                    LabeledContent("Cloudiest",
                                   value: "\(cloudiest.time.formatted(.dateTime.weekday(.abbreviated))) · \(EnvMetric.turbidity.format(cloudiest.value))")
                }
            } else {
                HealthWeekEmptyRow(systemImage: "drop", text: "Nearby water sensors don't measure water quality.")
            }
        } header: {
            Text("Water")
        } footer: {
            if week.waterStations > 0, let scale = week.water {
                Text("\(scale.footer) Measured in nearby streams and reservoirs, not your tap.")
            }
        }
    }

    @ViewBuilder
    private func waterChart(_ week: HealthWeekData, scale: HealthWeekScale) -> some View {
        let metric = scale.metric
        Chart {
            ForEach(week.waterDays) { day in
                if let average = day.average,
                   let low = day.hours.map(\.value).min(), let high = day.hours.map(\.value).max() {
                    AreaMark(
                        x: .value("Day", day.day, unit: .day),
                        yStart: .value("Lowest", low),
                        yEnd: .value("Highest", high)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.15))
                    .interpolationMethod(.monotone)
                    .accessibilityHidden(true)

                    LineMark(x: .value("Day", day.day, unit: .day), y: .value("Daily average", average))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                        .accessibilityLabel(day.day.formatted(.dateTime.weekday(.wide)))
                        .accessibilityValue("\(metric.plainName) \(scale.valueText(average)), \(scale.word(metric.level(average)))")

                    PointMark(x: .value("Day", day.day, unit: .day), y: .value("Daily average", average))
                        .symbol { HealthWeekDot(color: metric.level(average).color) }
                        .accessibilityHidden(true)
                }
            }
            ForEach(scale.goodLines, id: \.self) { line in
                RuleMark(y: .value("Good", line))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: week.weekDomain)
        .chartYScale(domain: week.waterDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) {
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
        }
        .chartYAxis { healthWeekYAxis(goodAt: scale.labelValue) }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .frame(height: 150)
        .padding(.top, 6)
        .accessibilityLabel("\(metric.plainName) by day")

        HealthWeekLegendRow {
            HealthWeekLegend(text: "Daily average") {
                Capsule().fill(Color.accentColor).frame(width: 14, height: 3)
            }
            HealthWeekLegend(text: "Daily range") {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.25)).frame(width: 14, height: 10)
            }
        }
        .padding(.bottom, 2)
        .accessibilityHidden(true)
    }

    // MARK: States

    private var noPermission: some View {
        ContentUnavailableView {
            Label("Your week of air and water", systemImage: "location.circle")
        } description: {
            Text("Dewin uses your rough location, about 1 km, to find air and water sensors near you.")
        } actions: {
            if location.authorization == .denied || location.authorization == .restricted {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Use my location") { location.requestPermission() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(location.lastLocation == nil ? "Finding where you are…" : "Checking the air and water near you…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func loadFailed(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load your week", systemImage: "wifi.exclamationmark")
        } description: {
            Text(error)
        } actions: {
            Button("Try again") { reloadNow() }
                .buttonStyle(.borderedProminent)
                .disabled(location.lastLocation == nil)
        }
    }

    private var noStations: some View {
        ContentUnavailableView {
            Label("No sensors near you", systemImage: "mappin.slash")
        } description: {
            Text("Dewin found no air or water sensors within 15 km this week.")
        } actions: {
            Button("Open the map") { router.open(.map) }
                .buttonStyle(.bordered)
        }
    }

    // MARK: Loading

    private func reloadNow() {
        if let coordinate = location.lastLocation?.coordinate { nearby.refresh(around: coordinate, force: true) }
    }

    /// Pull to refresh: starts a forced reload and waits for it, so the spinner stays until data lands.
    private func reload() async {
        reloadNow()
        try? await Task.sleep(for: .milliseconds(300))
        while nearby.isLoading { try? await Task.sleep(for: .milliseconds(200)) }
    }
}

// MARK: - Week data

/// Everything the week screen shows, computed once per load.
@MainActor
private struct HealthWeekData {
    /// What the air and water charts show: AQI / water quality index when nearby sensors report one,
    /// else the best raw reading (live Dewin sensors send PM2.5, turbidity, pH… and no index).
    let air: HealthWeekScale?
    let water: HealthWeekScale?

    let airDays: [HealthDay]
    let waterDays: [HealthDay]
    let turbidityDays: [HealthDay]
    let pollutants: [HealthWeekPollutant]
    let airStations: Int
    let waterStations: Int
    let sources: [String]
    let weekDomain: ClosedRange<Date>

    let goodDays: Int
    let hoursOverGood: Int
    let worstMoment: HourValue?
    let airDomain: ClosedRange<Double>

    let hourProfile: [HealthWeekHour]
    let hourChartMax: Double
    let cleanest: HealthWeekWindow?
    let dirtiest: HealthWeekWindow?

    let waterAverage: Double?
    let waterDomain: ClosedRange<Double>
    let cloudyDays: Int
    let cloudiest: HourValue?

    init(nearby: NearbyHealthStore, now: Date = .now, calendar: Calendar = .current) {
        let air = nearby.headlineMetric(.air).map(HealthWeekScale.init)
        let water = nearby.headlineMetric(.water).map(HealthWeekScale.init)
        self.air = air
        self.water = water

        let airDays = air.map { nearby.days($0.metric, now: now, calendar: calendar).filter(\.hasData) } ?? []
        let waterDays = water.map { nearby.days($0.metric, now: now, calendar: calendar).filter(\.hasData) } ?? []
        self.airDays = airDays
        self.waterDays = waterDays
        turbidityDays = water?.metric == .turbidity ? waterDays
            : nearby.days(.turbidity, now: now, calendar: calendar).filter(\.hasData)
        pollutants = [(EnvMetric.pm25, 9.0), (.o3, 54), (.no2, 53)].map { metric, limit in
            let days = metric == air?.metric ? airDays : nearby.days(metric, now: now, calendar: calendar)
            return HealthWeekPollutant(metric: metric, average: Self.average(days), limit: limit)
        }

        let nearbyAir = nearby.stations(.air)
        let nearbyWater = nearby.stations(.water)
        airStations = nearbyAir.count
        waterStations = nearbyWater.count
        var seen = Set<String>()
        sources = (nearbyAir + nearbyWater).compactMap(\.station.source).filter { seen.insert($0).inserted }

        // The same 7 days `days(...)` returns, today last.
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        weekDomain = first...(calendar.date(byAdding: .day, value: 1, to: today) ?? today)

        // Air by day
        goodDays = airDays.filter { $0.worstLevel == .good }.count
        hoursOverGood = airDays.reduce(0) { $0 + $1.hoursOverGood }
        worstMoment = airDays.compactMap(\.worst).max { $0.value < $1.value }
        airDomain = air?.domain(values: airDays.compactMap(\.worst?.value)) ?? 0...100

        // Air by hour of day, across the week
        var byHour: [Int: [Double]] = [:]
        for day in airDays {
            for hour in day.hours { byHour[calendar.component(.hour, from: hour.time), default: []].append(hour.value) }
        }
        let profile = byHour.keys.sorted().compactMap { hour -> HealthWeekHour? in
            guard let values = byHour[hour], !values.isEmpty else { return nil }
            return HealthWeekHour(hour: hour, average: values.reduce(0, +) / Double(values.count))
        }
        hourProfile = profile
        hourChartMax = max(1, (profile.map(\.average).max() ?? 0) * 1.3)
        // Two-hour windows during waking hours; needs a few days so one bad morning doesn't decide it.
        let averages = Dictionary(uniqueKeysWithValues: profile.map { ($0.hour, $0.average) })
        let windows = (5...20).compactMap { start -> HealthWeekWindow? in
            guard let a = averages[start], let b = averages[start + 1] else { return nil }
            return HealthWeekWindow(start: start, hours: 2, average: (a + b) / 2)
        }
        let enoughData = airDays.count >= 3 && windows.count >= 8
        cleanest = enoughData ? windows.min { $0.average < $1.average } : nil
        dirtiest = enoughData ? windows.max { $0.average < $1.average } : nil

        // Water
        waterAverage = Self.average(waterDays)
        waterDomain = water?.domain(values: waterDays.flatMap(\.hours).map(\.value)) ?? 0...100
        cloudyDays = turbidityDays.filter { ($0.worstLevel ?? .good) >= .sensitive }.count
        cloudiest = turbidityDays.compactMap(\.worst).max { $0.value < $1.value }
    }

    /// Mean of every hour in the week (not of daily means, so a half-measured day counts less).
    static func average(_ days: [HealthDay]) -> Double? {
        let values = days.flatMap(\.hours).map(\.value)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    func pollutant(_ metric: EnvMetric) -> HealthWeekPollutant? { pollutants.first { $0.metric == metric } }

    /// One action for the "best time" section.
    func bestTimeAction(scale: HealthWeekScale, clean: HealthWeekWindow, dirty: HealthWeekWindow) -> String {
        if scale.metric.level(dirty.average) == .good, dirty.average - clean.average < scale.goodLines[0] * 0.2 {
            return "Air stayed clean all day. Any time works this week."
        }
        if clean.end <= 9 { return "Plan runs before \(HealthWeekWindow.hourText(clean.end)) this week." }
        return "Plan runs and walks for \(clean.rangeText) this week."
    }

    /// Up to 3 actions, worst finding first. EPA AirNow-style: one action per finding.
    var tips: [Insights.Tip] {
        guard !airDays.isEmpty || !waterDays.isEmpty || !turbidityDays.isEmpty else {
            return [.init(kind: .info, text: "Tips show up once Dewin has a few days of readings near you.")]
        }
        var tips: [Insights.Tip] = []

        if let air {
            let badDays = airDays.filter { ($0.worstLevel ?? .good) >= .sensitive }
            if let worstDay = badDays.max(by: { ($0.worst?.value ?? 0) < ($1.worst?.value ?? 0) }) {
                let name = worstDay.day.formatted(.dateTime.weekday(.wide))
                let what = air.metric == .aqi ? "Air passed AQI 100" : "\(air.metric.plainName) reached unhealthy levels"
                let action = air.metric == .co2 ? "open a window or step outside for a while" : "keep outdoor workouts short"
                tips.append(.init(kind: .warning, text: badDays.count == 1
                    ? "\(what) on \(name). On days like that, \(action)."
                    : "\(what) on \(badDays.count) days, worst on \(name). On those days, \(action)."))
            }
        }

        let peak = dirtiest.map { " Keep windows closed \($0.rangeText), when they peak." } ?? ""
        if let pm25 = pollutant(.pm25), let value = pm25.average, value > pm25.limit {
            tips.append(.init(kind: .warning,
                              text: "Fine particles averaged \(EnvMetric.pm25.format(value)), over the \(EnvMetric.pm25.format(pm25.limit)) limit.\(peak)"))
        } else if let air, let dirtiest, air.metric.level(dirtiest.average) > .good {
            tips.append(.init(kind: .info, text: "Air is dirtiest \(dirtiest.rangeText). Keep windows closed then."))
        }
        if let o3 = pollutant(.o3), let value = o3.average, value > o3.limit {
            tips.append(.init(kind: .info, text: "Ozone builds in the afternoon. Exercise outside before noon."))
        }
        if let no2 = pollutant(.no2), let value = no2.average, value > no2.limit {
            tips.append(.init(kind: .info, text: "Traffic fumes ran high. Walk on side streets, away from main roads."))
        }

        // Water: cloudiness first (it has a tap action), else the week's overall quality.
        let waterLevel = water.flatMap { scale in waterAverage.map(scale.metric.level) }
        if cloudyDays > 0 {
            tips.append(.init(kind: .warning, text: cloudyDays == 1
                ? "Local water turned cloudy on 1 day. If your tap looks cloudy, run it for 2 minutes first."
                : "Local water turned cloudy on \(cloudyDays) days. If your tap looks cloudy, run it for 2 minutes first."))
        } else if let water, let average = waterAverage, let waterLevel, waterLevel >= .sensitive {
            let what = water.metric == .wqi ? "Nearby water quality averaged \(water.valueText(average))"
                : "\(water.metric.plainName) in nearby water averaged \(water.valueText(average))"
            tips.append(.init(kind: .warning,
                              text: "\(what), \(water.word(waterLevel).lowercased()). Skip swimming or wading in local streams."))
        }

        if tips.isEmpty, !airDays.isEmpty {
            if goodDays * 2 >= airDays.count, let cleanest {
                tips.append(.init(kind: .good, text: "\(goodDays) of \(airDays.count) days had good air. Air out your home \(cleanest.rangeText)."))
            } else if goodDays * 2 < airDays.count {
                tips.append(.init(kind: .info, text: "Air was only fair most days. If you're sensitive, take it easier on long outdoor workouts."))
            }
        }
        if tips.isEmpty, (waterLevel ?? .good) <= .moderate {
            tips.append(.init(kind: .good, text: "Air and water were fine this week. Nothing to change."))
        }

        // Warnings before info before good; ties keep the order above.
        func rank(_ kind: Insights.Tip.Kind) -> Int {
            switch kind {
            case .warning: 0
            case .info: 1
            case .good: 2
            }
        }
        return tips.enumerated()
            .sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }
            .prefix(3)
            .map(\.element)
    }

    var sourceLine: String {
        var parts: [String] = []
        if airStations > 0 { parts.append(airStations == 1 ? "1 air sensor" : "\(airStations) air sensors") }
        if waterStations > 0 { parts.append(waterStations == 1 ? "1 water sensor" : "\(waterStations) water sensors") }
        let sensors = parts.joined(separator: " and ")
        let from = sources.isEmpty ? "" : " Data: \(sources.joined(separator: ", "))."
        return "From \(sensors) within 15 km, closest weighted most.\(from)"
    }
}

/// How to read one headline metric here: where "good" ends, the chart's range, and its words.
private struct HealthWeekScale {
    let metric: EnvMetric

    /// The edge of "good": one line, or both edges of the good band for pH (and comfort ranges).
    var goodLines: [Double] {
        switch metric {
        case .aqi: [50]
        case .pm25: [9]
        case .pm10, .o3: [54]
        case .no2: [53]
        case .co2: [800]
        case .wqi: [90]
        case .turbidity: [1]
        case .ph: [6.5, 8.5]
        case .tds: [300]
        case .conductivity: [800]
        case .dissolvedOxygen: [7]
        case .temperature: [20]
        case .humidity: [30, 60]
        case .airTemperature: [18, 27]
        }
    }

    /// Where the "Good" axis label sits: on the line, or mid-band.
    var labelValue: Double { goodLines.reduce(0, +) / Double(goodLines.count) }

    /// The chart's y range: the good line always shows, with room above the worst reading.
    func domain(values: [Double]) -> ClosedRange<Double> {
        if metric == .wqi { return 0...100 }
        if goodLines.count == 2 {
            let pad = (goodLines[1] - goodLines[0]) / 2
            let low = min(goodLines[0] - pad, values.min() ?? goodLines[0]).rounded(.down)
            let high = max(goodLines[1] + pad, values.max() ?? goodLines[1]).rounded(.up)
            return low...high
        }
        let good = goodLines[0], step = good / 2
        let top = max(good * 2, (values.max() ?? 0) * 1.1)
        return 0...((top / step).rounded(.up) * step)
    }

    /// "AQI 79", "68 of 100", "15 µg/m³", "pH 7.2".
    func valueText(_ value: Double) -> String {
        switch metric {
        case .aqi: "AQI \(Int(value.rounded()))"
        case .wqi: "\(Int(value.rounded())) of 100"
        case .ph: "pH \(metric.format(value))"
        default: metric.format(value)
        }
    }

    /// A short level word. Water gets its own: "unhealthy for sensitive groups" is an air phrase.
    func word(_ level: EnvLevel) -> String {
        guard metric.kind == .water else { return level.label }
        switch level {
        case .good: return "Good"
        case .moderate: return "Fair"
        case .sensitive: return "Poor"
        case .unhealthy: return "Very poor"
        case .hazardous: return "Severe"
        }
    }

    /// "Fine particles (PM2.5), daily average. Lower is better. Good is up to 9 µg/m³."
    var footer: String {
        let rule: String = switch metric {
        case .aqi: "Lower is better. 0–50 is good."
        case .wqi: "Higher is better. 90 and up is good."
        case .ph, .humidity, .airTemperature: "\(metric.format(goodLines[0])) to \(metric.format(goodLines[1])) is good."
        default: metric.lowerIsWorse
            ? "Higher is better. Good is \(metric.format(goodLines[0])) and up."
            : "Lower is better. Good is up to \(metric.format(goodLines[0]))."
        }
        guard metric != .aqi, metric != .wqi else { return rule }
        let name = metric.plainName.contains(metric.label) ? metric.plainName : "\(metric.plainName) (\(metric.label))"
        return "\(name), daily average. \(rule)"
    }
}

private struct HealthWeekHour: Identifiable {
    let hour: Int
    let average: Double
    var id: Int { hour }
}

/// A run of hours of the day, e.g. 5–7 AM. Formatted with the locale, so 24-hour clocks read "05–07".
private struct HealthWeekWindow {
    let start: Int
    let hours: Int
    let average: Double

    var end: Int { start + hours }
    func contains(_ hour: Int) -> Bool { hour >= start && hour < end }

    /// "5 – 7 AM" on a 12-hour clock, "05:00–07:00" on a 24-hour one.
    var rangeText: String {
        Self.uses24Hour ? "\(Self.hourText(start))–\(Self.hourText(end))"
            : (Self.date(start)..<Self.date(end)).formatted(.interval.hour())
    }

    /// "5 AM" or "05:00", following the locale like the other Health screens.
    static func hourText(_ hour: Int) -> String {
        uses24Hour ? date(hour).formatted(date: .omitted, time: .shortened)
            : date(hour).formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }

    /// "Tue 4 PM", "Tue 16:00".
    static func momentText(_ time: Date, calendar: Calendar = .current) -> String {
        "\(time.formatted(.dateTime.weekday(.abbreviated))) \(hourText(calendar.component(.hour, from: time)))"
    }

    /// A bare "08" reads as a date, so 24-hour clocks get minutes too.
    private static var uses24Hour: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }

    /// Today at `hour` o'clock (24 is tomorrow's midnight).
    private static func date(_ hour: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: calendar.startOfDay(for: .now)) ?? .now
    }
}

private struct HealthWeekPollutant: Identifiable {
    let metric: EnvMetric
    let average: Double?
    /// Top of EPA "good" for this pollutant.
    let limit: Double
    var id: EnvMetric { metric }
}

// MARK: - Pieces

/// The y axis of the day charts: values on the right, "Good" on the left at the good line, outside the plot.
@AxisContentBuilder
private func healthWeekYAxis(goodAt: Double) -> some AxisContent {
    AxisMarks(position: .trailing)
    AxisMarks(position: .leading, values: [goodAt]) { _ in
        AxisValueLabel {
            Text("Good").font(.caption2.weight(.medium))
        }
    }
}

/// A stat value with its level spelled out under it, so the dot is never the only cue.
private struct HealthWeekLevelValue: View {
    let text: String
    let word: String
    let color: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(text).monospacedDigit()
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(word).font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.trailing)
    }
}

/// Pollutant name, weekly average, and a bar against the "good" limit (the tick sits at the limit).
private struct HealthWeekPollutantRow: View {
    let pollutant: HealthWeekPollutant

    var body: some View {
        let metric = pollutant.metric
        let level = pollutant.average.map(metric.level)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.plainName).font(.subheadline)
                Spacer()
                Text(pollutant.average.map(metric.format) ?? "–")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            HealthWeekLimitBar(fraction: (pollutant.average ?? 0) / pollutant.limit, color: level?.color ?? .gray)
            HStack(spacing: 6) {
                Circle().fill(level?.color ?? .gray).frame(width: 8, height: 8)
                Text(caption(level: level))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.plainName)
        .accessibilityValue(pollutant.average.map { "\(metric.format($0)) weekly average, \(level?.label ?? ""). Good is up to \(metric.format(pollutant.limit))." }
            ?? "No readings")
    }

    private func caption(level: EnvLevel?) -> String {
        let metric = pollutant.metric
        var parts: [String] = []
        if !metric.plainName.contains(metric.label) { parts.append(metric.label) }
        parts.append(level?.label ?? "No readings")
        parts.append("good up to \(metric.format(pollutant.limit))")
        return parts.joined(separator: " · ")
    }
}

/// The limit sits at the middle of the track, so "twice the limit" fills it.
private struct HealthWeekLimitBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule().fill(color).frame(width: max(8, width * min(fraction / 2, 1)))
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 2, height: 14)
                    .offset(x: width / 2 - 1)
            }
        }
        .frame(height: 8)
        .padding(.vertical, 3)
    }
}

/// A chart dot with a ring, so it reads over bars and lines.
private struct HealthWeekDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
    }
}

private struct HealthWeekLegend<Swatch: View>: View {
    let text: String
    @ViewBuilder let swatch: Swatch

    var body: some View {
        HStack(spacing: 6) {
            swatch
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Legend items side by side, or stacked when large text doesn't fit them on one line.
private struct HealthWeekLegendRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { content }
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }
}

private struct HealthWeekEmptyRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
