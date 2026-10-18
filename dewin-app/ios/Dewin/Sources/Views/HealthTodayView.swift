import Charts
import SwiftUI
import UIKit

/// Health › Today: the air and water around you right now, today's air by hour, what's in it,
/// the nearest water sensor, and a way into the 90-day report and the map.
///
/// Headlines follow `NearbyHealthStore.headlineMetric`: AQI / water quality index when the sensors
/// report one, else the best raw reading (PM2.5, turbidity…). Live Dewin sensors send raw values only.
struct HealthTodayView: View {
    @Environment(LocationReporter.self) private var location
    @Environment(NearbyHealthStore.self) private var nearby
    @Environment(ReportStore.self) private var report
    @Environment(Router.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let now = Date()

        List {
            if !location.isAuthorized {
                Section { permissionCard }
            } else if nearby.series == nil {
                Section { loadingOrError }
            } else {
                airNowSection(now: now)
                if !nearby.stations(.air).isEmpty {
                    todaysAirSection(now: now)
                    pollutantsSection(now: now)
                }
                waterSection(now: now)
            }

            Section { reportCard }
                .listRowBackground(Brand.navy)

            if location.isAuthorized {
                Section { mapRow }
            }
        }
        .refreshable {
            async let reportLoad: Void = report.load(force: true)
            await reloadNearby()
            await reportLoad
        }
        .task { await report.load() }
    }

    /// `refresh` starts its own task; wait for it so the pull-to-refresh spinner stays until readings land.
    private func reloadNearby() async {
        guard let coordinate = location.lastLocation?.coordinate else { return }
        nearby.refresh(around: coordinate, force: true)
        let deadline = Date().addingTimeInterval(20)
        try? await Task.sleep(for: .milliseconds(100))
        while nearby.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    // MARK: States

    private var permissionCard: some View {
        let denied = location.authorization == .denied || location.authorization == .restricted
        // Live Dewin sensors match you within ~100 m, so that mode shares precise fixes.
        let privacy = EnvlabSettings.current.mode == .live
            ? "Dewin matches you with its sensors within about 100 m, so it shares your precise location while the app is open. To stop, pick Sample data in Settings › Air & water data."
            : "Dewin finds the air and water sensors near you. Your location is rounded to about 1 km before it leaves your phone."
        return VStack(spacing: 14) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Brand.teal, Brand.teal.opacity(0.18))
                .accessibilityHidden(true)
            Text("See the air and water around you")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(privacy)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if denied, let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                } else {
                    location.requestPermission()
                }
            } label: {
                Text(denied ? "Turn on location in Settings" : "Allow location")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Teal keeps white text readable in dark mode, where the accent is light aqua.
            .tint(Brand.teal)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var loadingOrError: some View {
        if let error = nearby.error, !nearby.isLoading {
            VStack(alignment: .leading, spacing: 10) {
                Label("Couldn't load air and water readings", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Try again") {
                    if let c = location.lastLocation?.coordinate { nearby.refresh(around: c, force: true) }
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 6)
        } else {
            HStack(spacing: 12) {
                ProgressView()
                Text(location.lastLocation == nil ? "Finding where you are…" : "Finding sensors near you…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    // MARK: Air now

    private func airNowSection(now: Date) -> some View {
        let stations = nearby.stations(.air)
        let metric = nearby.headlineMetric(.air)
        // Sensors with a recent reading of the headline metric, nearest first.
        let measuring = metric.map { metric in
            stations.compactMap { entry -> (station: EnvSeries.Station, reading: EnvSeries.Reading, distanceKm: Double)? in
                guard let reading = entry.station.reading(at: now), reading.values[metric.rawValue] != nil else { return nil }
                return (entry.station, reading, entry.distanceKm)
            }
        } ?? []
        let nearest = measuring.first
        let blended = metric.flatMap { nearby.areaValue($0, at: now) }
        let raw = blended ?? metric.flatMap { nearest?.reading.values[$0.rawValue] }

        return Section {
            if let metric, let raw {
                let reading = HealthTodayReading(metric: metric, raw: raw)
                let side: CGFloat = dynamicTypeSize.isAccessibilitySize ? 170 : 130
                let gauge = HealthTodayGauge(reading: reading).frame(width: side, height: side)
                let details = airNowDetails(reading: reading, nearest: nearest,
                                            sensorCount: blended == nil ? 1 : measuring.count)
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 14) {
                            gauge.frame(maxWidth: .infinity)
                            details
                        }
                    } else {
                        HStack(spacing: 20) {
                            gauge
                            details
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(airNowLabel(reading: reading, nearest: nearest,
                                                sensorCount: blended == nil ? 1 : measuring.count))

                TipRow(tip: HealthTodayAdvice.air(reading))
            } else if stations.isEmpty {
                HealthTodayEmptyRow(
                    systemImage: "aqi.medium",
                    title: "No air sensors within \(Int(NearbyHealthStore.maxDistanceKm)) km",
                    detail: "Open the map to see the closest ones."
                )
            } else {
                HealthTodayEmptyRow(
                    systemImage: "clock.badge.questionmark",
                    title: "No reading from nearby sensors in the last 3 hours",
                    detail: "\(stations.count) \(stations.count == 1 ? "sensor is" : "sensors are") within \(Int(NearbyHealthStore.maxDistanceKm)) km. Pull down to check again."
                )
            }
        } header: {
            Text("Air now")
        } footer: {
            if let error = nearby.error {
                Text("Couldn't refresh: \(error)")
            }
        }
    }

    private func airNowDetails(reading: HealthTodayReading,
                               nearest: (station: EnvSeries.Station, reading: EnvSeries.Reading, distanceKm: Double)?,
                               sensorCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HealthTodayLevelDot(level: reading.level, size: 10)
                Text(reading.level.label)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let nearest {
                VStack(alignment: .leading, spacing: 1) {
                    Text(sensorCount > 1 ? "Your area · \(sensorCount) sensors" : "From the nearest sensor")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(nearest.station.name ?? "Air sensor") · \(km(nearest.distanceKm)) km")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Hourly average from \(nearest.reading.t.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func airNowLabel(reading: HealthTodayReading,
                             nearest: (station: EnvSeries.Station, reading: EnvSeries.Reading, distanceKm: Double)?,
                             sensorCount: Int) -> String {
        var text = "\(reading.spokenName) \(reading.text), \(reading.level.label)."
        if let nearest {
            text += sensorCount > 1 ? " Your area, from \(sensorCount) sensors." : " From the nearest sensor."
            text += " Nearest: \(nearest.station.name ?? "air sensor"), \(km(nearest.distanceKm)) kilometers away."
            text += " Hourly average from \(nearest.reading.t.formatted(date: .omitted, time: .shortened))."
        }
        return text
    }

    // MARK: Today's air

    private func todaysAirSection(now: Date) -> some View {
        let calendar = Calendar.current
        let metric = nearby.headlineMetric(.air)
        let hours = metric.map { nearby.hourly($0, now: now) } ?? []

        return Section {
            if let metric, !hours.isEmpty {
                let today = HealthDay(day: calendar.startOfDay(for: now), metric: metric, hours: hours)
                HealthTodayAirChart(metric: metric, hours: hours, now: now)
                    .padding(.top, 8)
                if let best = today.best, let worst = today.worst {
                    let bestTile = HealthTodayHourTile(title: "Best hour", systemImage: "arrow.down.circle.fill",
                                                       hour: best, metric: metric)
                    let worstTile = HealthTodayHourTile(title: "Worst hour", systemImage: "arrow.up.circle.fill",
                                                        hour: worst, metric: metric)
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 12) { bestTile; worstTile }
                    } else {
                        HStack(alignment: .top, spacing: 12) { bestTile; worstTile }
                    }
                }
            } else {
                Text("No readings yet today.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Today's air")
        } footer: {
            if let metric, !hours.isEmpty {
                Text("Dashed line: the top of “Good” (\(metric.label) \(metric.format(HealthTodayScale.goodLimit(metric)))).")
            }
        }
    }

    // MARK: What's in the air

    private func pollutantsSection(now: Date) -> some View {
        let all: [(metric: EnvMetric, value: Double?)] = HealthTodayScale.pollutants.map { ($0, nearby.areaValue($0, at: now)) }
        let measured = all.compactMap { row in row.value.map { HealthTodayReading(metric: row.metric, raw: $0) } }
        let missing = all.filter { $0.value == nil }.map(\.metric.plainName)

        return Section {
            if measured.isEmpty {
                Text("No particle or gas readings nearby right now.").foregroundStyle(.secondary)
            } else {
                ForEach(measured, id: \.metric) { reading in
                    HealthTodayPollutantRow(reading: reading)
                }
            }
        } header: {
            Text("What's in the air")
        } footer: {
            if !measured.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The mark on each bar is the limit for good air. Readings are hourly; the limits are set for daily (particles) and 8-hour (ozone) averages.")
                    if !missing.isEmpty {
                        Text("Not measured nearby: \(missing.joined(separator: ", ")).")
                    }
                }
            }
        }
    }

    // MARK: Water near you

    private func waterSection(now: Date) -> some View {
        let stations = nearby.stations(.water)
        let nearest = nearby.nearest(.water, now: now)
        let isDewin = nearest?.station.source?.localizedCaseInsensitiveContains("dewin") ?? false

        return Section {
            if let nearest {
                let values = nearest.reading.values
                let headline = EnvMetric.headline(.water, in: values).map { HealthTodayReading(metric: $0.metric, raw: $0.value) }
                // Headline first, then the rest in a fixed order. Water temperature is never the headline.
                let order: [EnvMetric] = [.wqi, .turbidity, .ph, .dissolvedOxygen, .tds, .conductivity, .temperature]
                let rows = ([headline?.metric].compactMap { $0 } + order.filter { $0 != headline?.metric })
                    .compactMap { metric in values[metric.rawValue].map { HealthTodayReading(metric: metric, raw: $0) } }

                HStack(spacing: 12) {
                    Image(systemName: "drop.fill")
                        .font(.title3)
                        .foregroundStyle(Brand.blue)
                        .frame(width: 36, height: 36)
                        .background(Brand.blue.opacity(0.14), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nearest.station.name ?? "Water sensor").font(.headline)
                        Text("\(isDewin ? "Dewin sensor" : "Public sensor in local water") · \(km(nearest.distanceKm)) km away")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                ForEach(rows, id: \.metric) { reading in
                    HealthTodayWaterRow(reading: reading, isHeadline: reading.metric == headline?.metric)
                }

                if let tip = HealthTodayAdvice.water(headline, turbidity: values[EnvMetric.turbidity.rawValue]) {
                    TipRow(tip: tip)
                }
            } else if stations.isEmpty {
                HealthTodayEmptyRow(
                    systemImage: "drop",
                    title: "No water sensors within \(Int(NearbyHealthStore.maxDistanceKm)) km",
                    detail: "Open the map to see the closest ones."
                )
            } else {
                HealthTodayEmptyRow(
                    systemImage: "clock.badge.questionmark",
                    title: "No reading from nearby water sensors in the last 3 hours",
                    detail: "Pull down to check again."
                )
            }
        } header: {
            Text("Water near you")
        } footer: {
            if nearest != nil {
                Text(isDewin ? "From a Dewin water sensor near you. It may not be your tap."
                             : "This is water in local streams, ponds and reservoirs, not your tap water.")
            }
        }
    }

    // MARK: 90-day report

    @ViewBuilder
    private var reportCard: some View {
        if let data = report.report {
            Button { router.showReport = true } label: {
                HealthTodayReportCard(report: data)
            }
            .accessibilityHint("Opens your 90-day report")
        } else if report.isLoading {
            HStack(spacing: 12) {
                HealthTodayReportTitle()
                Spacer()
                ProgressView().tint(.white)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading your 90-day report")
        } else {
            // Failed, or nothing loaded yet (e.g. right after "Delete my data").
            Button { Task { await report.load(force: true) } } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HealthTodayReportTitle()
                    Text(report.error == nil ? "Tap to build your 90-day report." : "Couldn't load your report. Tap to try again.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    if let error = report.error {
                        Text(error).font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Map

    private var mapRow: some View {
        let count = nearby.stations(.air).count + nearby.stations(.water).count
        return Button { router.health = .map } label: {
            HStack {
                Label {
                    Text("Open the map").foregroundStyle(Color(.label))
                } icon: {
                    Image(systemName: "map.fill")
                }
                Spacer()
                if count > 0 {
                    Text("\(count) sensors nearby").font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
        }
    }

    private func km(_ distance: Double) -> String {
        distance.formatted(.number.precision(.fractionLength(1)))
    }
}

// MARK: - Values, scales and advice

/// A value rounded the way `EnvMetric.format` shows it, so the level always matches the number on screen
/// (an area blend of 50.3 shows "50", and 50 is Good).
private struct HealthTodayReading {
    let metric: EnvMetric
    let value: Double

    init(metric: EnvMetric, raw: Double) {
        self.metric = metric
        switch metric {
        case .aqi, .wqi: value = raw.rounded()
        case .ph: value = (raw * 10).rounded() / 10
        default: value = raw < 10 ? (raw * 10).rounded() / 10 : raw.rounded()
        }
    }

    var level: EnvLevel { metric.level(value) }
    /// "17 µg/m³", "50", "81".
    var text: String { metric.format(value) }
    /// The number alone, without its unit.
    var number: String {
        let unit = metric.unit
        return unit.isEmpty || unit == "/100" ? text : String(text.dropLast(unit.count + 1))
    }
    /// "Air quality index", "PM2.5" for VoiceOver.
    var spokenName: String { metric == .aqi ? "Air quality index" : metric.plainName }
}

/// Level breakpoints for the air metrics, matching `EnvMetric.level`. Gauges and bars give each level
/// an equal share of their length, so "Good" stays visible and a wildfire day doesn't look like a mildly bad one.
private enum HealthTodayScale {
    static let pollutants: [EnvMetric] = [.pm25, .o3, .no2, .pm10]

    /// Six edges: the start of Good, the top of Good, Moderate, Sensitive, Unhealthy, and the end of the scale.
    static func edges(_ metric: EnvMetric) -> [Double] {
        switch metric {
        case .pm25: [0, 9, 35.4, 55.4, 125.4, 225.4]
        case .pm10: [0, 54, 154, 254, 354, 424]
        case .o3: [0, 54, 70, 85, 105, 200]
        case .no2: [0, 53, 100, 360, 649, 1_249]
        case .co2: [0, 800, 1_000, 1_500, 2_500, 5_000]
        default: [0, 50, 100, 150, 200, 300] // AQI
        }
    }

    static func goodLimit(_ metric: EnvMetric) -> Double { edges(metric)[1] }

    /// 0–1 along the scale, each level band taking a fifth.
    static func position(_ value: Double, _ metric: EnvMetric) -> Double {
        let edges = edges(metric)
        let bands = Double(edges.count - 1)
        for index in 0..<(edges.count - 1) where value <= edges[index + 1] {
            let within = (value - edges[index]) / (edges[index + 1] - edges[index])
            return (Double(index) + min(max(within, 0), 1)) / bands
        }
        return 1
    }
}

/// One action per finding. AQI uses the shared EPA advice; raw pollutant readings get the same advice
/// for their level; CO₂ is about ventilation, not outdoor exercise.
private enum HealthTodayAdvice {
    static func air(_ reading: HealthTodayReading) -> Insights.Tip {
        if reading.metric == .aqi { return HealthAdvice.air(aqi: reading.value) }
        if reading.metric == .co2 {
            switch reading.level {
            case .good: return .init(kind: .good, text: "The air feels fresh. Nothing to do.")
            case .moderate: return .init(kind: .info, text: "Getting stuffy. Open a window for a few minutes.")
            default: return .init(kind: .warning, text: "The air is stuffy. Open a window or step outside for a break.")
            }
        }
        // A value in the middle of the matching AQI band, so the advice is the same as on the AQI scale.
        let aqi: Double = switch reading.level {
        case .good: 25
        case .moderate: 75
        case .sensitive: 125
        case .unhealthy: 175
        case .hazardous: 250
        }
        return HealthAdvice.air(aqi: aqi)
    }

    /// Advice for local surface water, not tap water. Nil when nothing worth headlining is measured.
    static func water(_ headline: HealthTodayReading?, turbidity: Double?) -> Insights.Tip? {
        if let turbidity, HealthTodayReading(metric: .turbidity, raw: turbidity).level >= .sensitive {
            return .init(kind: .warning, text: "This water is cloudy, likely from runoff. Skip swimming or wading here today.")
        }
        guard let headline else { return nil }
        switch headline.level {
        case .good:
            return .init(kind: .good, text: "Nearby water looks clean.")
        case .moderate:
            return .init(kind: .info, text: "Nearby water is fair today. Skip swimming after heavy rain.")
        default:
            return .init(kind: .warning, text: "Nearby water quality is low. Skip swimming or wading in local streams today.")
        }
    }
}

// MARK: - Pieces

/// Colored dot that sits next to a level's text label (never the only signal).
private struct HealthTodayLevelDot: View {
    let level: EnvLevel
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(level.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Level name on a soft tint of its color, for compact rows. Wraps rather than truncates: the label is
/// the signal that doesn't depend on color.
private struct HealthTodayLevelChip: View {
    let level: EnvLevel

    var body: some View {
        HStack(spacing: 4) {
            HealthTodayLevelDot(level: level, size: 6)
            Text(level.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(level.color.opacity(0.16), in: Capsule())
    }
}

private struct HealthTodayEmptyRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// 270° gauge for the air headline (AQI or a raw pollutant). Faint bands show the levels, each a fifth of
/// the arc; the solid arc is the value in its level color.
private struct HealthTodayGauge: View {
    let reading: HealthTodayReading

    private static let sweep = 0.75
    private static let lineWidth: CGFloat = 14

    var body: some View {
        let edges = HealthTodayScale.edges(reading.metric)
        let bands = edges.count - 1
        ZStack {
            // Start at the lower left so the gap sits at the bottom.
            ZStack {
                ForEach(0..<bands, id: \.self) { index in
                    Circle()
                        .trim(from: Double(index) / Double(bands) * Self.sweep,
                              to: Double(index + 1) / Double(bands) * Self.sweep)
                        .stroke((EnvLevel(rawValue: index) ?? .hazardous).color.opacity(0.28),
                                style: StrokeStyle(lineWidth: Self.lineWidth))
                }
                Circle()
                    .trim(from: 0, to: max(HealthTodayScale.position(reading.value, reading.metric) * Self.sweep, 0.01))
                    .stroke(reading.level.color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .animation(.easeOut, value: reading.value)
            }
            .rotationEffect(.degrees(135))

            VStack(spacing: 0) {
                Text(reading.number)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(reading.metric.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !reading.metric.unit.isEmpty {
                    Text(reading.metric.unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, Self.lineWidth + 6)
            // The ring has a fixed size; past this the number would run over the arc. VoiceOver reads the label.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.spokenName) \(reading.text), \(reading.level.label)")
    }
}

/// Today's air headline by hour, one bar per hour in its level color, with a line at "now".
private struct HealthTodayAirChart: View {
    let metric: EnvMetric
    let hours: [HourValue]
    let now: Date

    var body: some View {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        let ticks = [0, 6, 12, 18].compactMap { calendar.date(byAdding: .hour, value: $0, to: start) }
        let good = HealthTodayScale.goodLimit(metric)
        let top = max(good * 2, (hours.map(\.value).max() ?? 0) * 1.2)

        Chart {
            RuleMark(y: .value("Good", good))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .accessibilityHidden(true)

            ForEach(hours) { hour in
                let reading = HealthTodayReading(metric: metric, raw: hour.value)
                BarMark(x: .value("Hour", hour.time, unit: .hour), y: .value(metric.label, reading.value))
                    .foregroundStyle(reading.level.color.gradient)
                    .cornerRadius(3)
                    .accessibilityLabel(hour.time.formatted(.dateTime.hour()))
                    .accessibilityValue("\(metric.label) \(reading.text), \(reading.level.label)")
            }

            RuleMark(x: .value("Now", now))
                .foregroundStyle(.primary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .annotation(position: .top, spacing: 2) {
                    Text("Now").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: ticks) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
        }
        .frame(height: 150)
        // Fixed-height chart: past this the axis labels and "Now" crowd out the bars.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel("Today's \(metric == .aqi ? "air quality" : metric.plainName.lowercased()) by hour")
    }
}

private struct HealthTodayHourTile: View {
    let title: String
    let systemImage: String
    let hour: HourValue
    let metric: EnvMetric

    var body: some View {
        let reading = HealthTodayReading(metric: metric, raw: hour.value)
        let time = hour.time.formatted(date: .omitted, time: .shortened)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(reading.level.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(time)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text("\(metric.label) \(reading.text)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    HealthTodayLevelDot(level: reading.level, size: 6)
                    Text(reading.level.label).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(time), \(metric.label) \(reading.text), \(reading.level.label)")
    }
}

/// One pollutant: plain name, value, and a bar across its level bands where the mark is the top of "good".
private struct HealthTodayPollutantRow: View {
    let reading: HealthTodayReading
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let metric = reading.metric
        let level = reading.level
        let fraction = HealthTodayScale.position(reading.value, metric)
        let goodMark = HealthTodayScale.position(HealthTodayScale.goodLimit(metric), metric)
        let limit = Text("Good up to \(metric.format(HealthTodayScale.goodLimit(metric)))")
        let levelLabel = HStack(spacing: 4) {
            HealthTodayLevelDot(level: level)
            Text(level.label)
        }
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                // Stacked so long names don't hyphenate next to the value.
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.plainName).font(.subheadline.weight(.medium))
                    Text(reading.text).font(.subheadline.monospacedDigit())
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.plainName).font(.subheadline.weight(.medium))
                    if !metric.plainName.contains(metric.label) {
                        Text(metric.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(reading.text)
                        .font(.subheadline.monospacedDigit())
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<5, id: \.self) { index in
                            Rectangle().fill((EnvLevel(rawValue: index) ?? .hazardous).color.opacity(0.2))
                        }
                    }
                    .clipShape(Capsule())
                    Capsule().fill(level.color)
                        .frame(width: max(proxy.size.width * fraction, 6))
                    Rectangle()
                        .fill(.primary.opacity(0.55))
                        .frame(width: 2, height: 14)
                        .offset(x: proxy.size.width * goodMark - 1)
                }
            }
            .frame(height: 8)
            .padding(.vertical, 3)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) { levelLabel; limit }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        levelLabel
                        Spacer(minLength: 8)
                        limit.multilineTextAlignment(.trailing)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.plainName): \(reading.text), \(level.label). Good up to \(metric.format(HealthTodayScale.goodLimit(metric))).")
    }
}

/// One water reading: name, value and level. The level drops under the name when the row is too narrow.
private struct HealthTodayWaterRow: View {
    let reading: HealthTodayReading
    var isHeadline = false

    var body: some View {
        let name = Text(reading.metric.plainName)
            .font(isHeadline ? .subheadline.weight(.semibold) : .subheadline)
        let value = Text(reading.metric == .wqi ? "\(reading.text)/100" : reading.text)
            .font(isHeadline ? .subheadline.weight(.semibold).monospacedDigit() : .subheadline.monospacedDigit())
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                name
                Spacer(minLength: 8)
                value
                HealthTodayLevelChip(level: reading.level)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    name.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    value
                }
                HealthTodayLevelChip(level: reading.level)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.metric.plainName): \(reading.text)\(reading.metric == .wqi ? " out of 100" : ""), \(reading.level.label)")
    }
}

// MARK: - Report teaser

private struct HealthTodayReportTitle: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("Mark")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text("How you dewin?")
                .font(.headline)
                .foregroundStyle(.white)
        }
    }
}

/// A navy preview of the 90-day report: score, the one-line summary and the day strip.
private struct HealthTodayReportCard: View {
    let report: ExposureReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HealthTodayReportTitle()
                    Text("Last \(report.days) days · \(report.rangeLabel)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(report.score)")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(report.scoreLevel.color)
                    Text("/ 100")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Text(report.summary)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            HealthTodayDayStrip(days: report.timeline)
                .frame(height: 14)

            HStack {
                Text("See the full report")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.aqua)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Brand.aqua)
                Spacer()
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("How you dewin? Last \(report.days) days. Score \(report.score) out of 100. \(report.summary)")
    }
}

/// One block per day in the report's three colors. Days with no data are a faint block: a gap isn't "clean".
private struct HealthTodayDayStrip: View {
    let days: [ExposureReport.TimelineDay]

    var body: some View {
        Canvas { context, size in
            guard !days.isEmpty else { return }
            let gap: CGFloat = 1
            let width = max((size.width - gap * CGFloat(days.count - 1)) / CGFloat(days.count), 0.5)
            for (index, day) in days.enumerated() {
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                let color = day.isGap ? Color.white.opacity(0.12) : day.level.color
                context.fill(Path(roundedRect: rect, cornerRadius: min(width / 2, 1.5)), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}
