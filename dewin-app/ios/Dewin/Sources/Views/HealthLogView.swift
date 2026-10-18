import SwiftUI
import UIKit

/// Health › Log: your area's air and water hour by hour for the last 7 days, grouped by day,
/// newest first. Rows expand in place to show every reading for that hour. Mirrors Food › Log.
struct HealthLogView: View {
    @Environment(LocationReporter.self) private var location
    @Environment(NearbyHealthStore.self) private var nearby
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL

    /// `nearby.log()` grouped by day. Rebuilt only when new data loads; it walks every hour × metric × station.
    @State private var days: [HealthLogDay] = []
    @State private var sensorCount = (air: 0, water: 0)
    @State private var filter: HealthLogFilter = .all
    @State private var kinds: HealthLogKinds = .both

    var body: some View {
        List {
            if case .ready = state {
                content
            }
        }
        .overlay {
            switch state {
            case .ready: EmptyView()
            case let .needsPermission(denied): permissionView(denied: denied)
            case .locating: HealthLogProgress(text: "Finding where you are…")
            case .loading: HealthLogProgress(text: "Loading your area's readings…")
            case let .failed(message): failedView(message)
            case .noSensors: noSensorsView
            case .noReadings:
                ContentUnavailableView("No readings yet", systemImage: "clock",
                                       description: Text("Sensors near you haven't reported in the last 7 days. Pull down to check again."))
            }
        }
        .task(id: nearby.lastLoaded) { rebuild() }
        .refreshable { await reload() }
    }

    // MARK: Loaded

    @ViewBuilder
    private var content: some View {
        let shown = days.compactMap { $0.filtered(filter, kinds) }

        Section {
            HealthLogSummary(days: days, kinds: $kinds, filter: $filter)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let error = nearby.error {
                    Label("Couldn't refresh: \(error)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(sourceLine)
                if let lastLoaded = nearby.lastLoaded {
                    Text("Updated \(lastLoaded.formatted(.relative(presentation: .named))). Pull down to refresh.")
                }
            }
        }

        if shown.isEmpty {
            Section {
                ContentUnavailableView {
                    if filter == .over {
                        Label("No hours over the limit", systemImage: "checkmark.seal")
                    } else {
                        Label("No readings", systemImage: "clock")
                    }
                } description: {
                    Text(filter == .over
                         ? "No \(kinds.noun) reading near you reached the limit this week."
                         : "Sensors near you haven't reported \(kinds.noun) readings this week.")
                }
                .listRowBackground(Color.clear)
            }
        }

        ForEach(shown) { day in
            Section {
                ForEach(day.hours) { hour in
                    HealthLogRow(hour: hour, kinds: kinds)
                }
            } header: {
                HealthLogDayHeader(day: day, kinds: kinds)
            }
        }
    }

    private var sourceLine: String {
        let air = kinds.shows(.air) ? sensorCount.air : 0
        let water = kinds.shows(.water) ? sensorCount.water : 0
        let parts = [air > 0 ? "\(air) air" : nil, water > 0 ? "\(water) water" : nil].compactMap { $0 }
        let limit = "Over the limit means unhealthy for sensitive groups or worse (an AQI over 100)."
        guard !parts.isEmpty else { return limit }
        let noun = air + water == 1 ? "sensor" : "sensors"
        return "Blended from \(parts.joined(separator: " and ")) \(noun) within \(Int(NearbyHealthStore.maxDistanceKm)) km. "
            + limit
    }

    // MARK: Empty states

    private enum ScreenState {
        case ready, needsPermission(denied: Bool), locating, loading, failed(String), noSensors, noReadings
    }

    private var state: ScreenState {
        if !location.isAuthorized {
            return .needsPermission(denied: location.authorization == .denied || location.authorization == .restricted)
        }
        if !days.isEmpty { return .ready }
        if nearby.isLoading { return .loading }
        if let error = nearby.error { return .failed(error) }
        if nearby.lastLoaded == nil { return location.lastLocation == nil ? .locating : .loading }
        if sensorCount.air + sensorCount.water == 0 { return .noSensors }
        return .noReadings
    }

    private func permissionView(denied: Bool) -> some View {
        ContentUnavailableView {
            Label(denied ? "Location is off for Dewin" : "See the air and water near you", systemImage: "location.circle")
        } description: {
            Text(denied
                 ? "Turn on location in Settings to see your area's hour-by-hour readings."
                 : "Dewin uses your rough location (about 1 km) to find air and water sensors near you.")
        } actions: {
            if denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Allow location") { location.requestPermission() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func failedView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load readings", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { Task { await reload() } }
                .buttonStyle(.borderedProminent)
                .disabled(location.lastLocation == nil)
        }
    }

    private var noSensorsView: some View {
        ContentUnavailableView {
            Label("No sensors near you", systemImage: "sensor")
        } description: {
            Text("There are no air or water sensors within \(Int(NearbyHealthStore.maxDistanceKm)) km yet. The map shows the closest ones.")
        } actions: {
            Button("Open the map") { router.open(.map) }
                .buttonStyle(.bordered)
        }
    }

    // MARK: Data

    private func rebuild() {
        let calendar = Calendar.current
        // log() reaches back to midnight 7 days ago (8 calendar days); keep today + 6, like Health › Week.
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: .now)) ?? .distantPast
        var result: [HealthLogDay] = []
        for snapshot in nearby.log(calendar: calendar) where snapshot.time >= start { // newest first
            let day = calendar.startOfDay(for: snapshot.time)
            let hour = HealthLogHour(snapshot: snapshot)
            if let last = result.indices.last, result[last].day == day {
                result[last].hours.append(hour)
            } else {
                result.append(HealthLogDay(day: day, hours: [hour]))
            }
        }
        days = result
        sensorCount = (nearby.stations(.air).count, nearby.stations(.water).count)
    }

    /// Pull to refresh: force a reload and wait for it so the spinner means something.
    /// Stops waiting if the refresh is cancelled (e.g. the user switches segments).
    private func reload() async {
        guard let coordinate = location.lastLocation?.coordinate else { return }
        nearby.refresh(around: coordinate, force: true)
        do {
            try await Task.sleep(for: .milliseconds(250))
            while nearby.isLoading { try await Task.sleep(for: .milliseconds(200)) }
        } catch {
            return
        }
    }
}

// MARK: - Model

private enum HealthLogFilter: Hashable { case all, over }

private enum HealthLogKinds: String, CaseIterable, Identifiable {
    case both, air, water
    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: "Air & water"
        case .air: "Air only"
        case .water: "Water only"
        }
    }

    var noun: String {
        switch self {
        case .both: "air and water"
        case .air: "air"
        case .water: "water"
        }
    }

    var symbol: String {
        switch self {
        case .both: "line.3.horizontal.decrease.circle"
        case .air: EnvKind.air.symbol
        case .water: EnvKind.water.symbol
        }
    }

    func shows(_ kind: EnvKind) -> Bool { self == .both || rawValue == kind.rawValue }
    var shown: [EnvKind] { EnvKind.allCases.filter(shows) }
}

/// "Over the limit": unhealthy for sensitive groups or worse (AQI over 100, EPA's orange), on a
/// health reading. Moderate is normal on most days and doesn't count.
private let healthLogLimit = EnvLevel.sensitive

private extension EnvMetric {
    /// Readings with a health limit. Humidity, temperatures and conductivity are comfort or
    /// background readings: shown, but they never put an hour over the limit.
    var healthLogIsHealthLimit: Bool {
        switch self {
        case .aqi, .pm25, .pm10, .o3, .no2, .co2, .wqi, .ph, .turbidity, .dissolvedOxygen, .tds: true
        case .humidity, .airTemperature, .temperature, .conductivity: false
        }
    }
}

/// The reading a kind's chip shows: the index when measured, else the best raw health reading.
private struct HealthLogReading {
    let metric: EnvMetric
    let value: Double
    var level: EnvLevel { metric.level(value) }
    var text: String { metric.format(value) }
    var isIndex: Bool { metric == .aqi || metric == .wqi }

    /// "air quality 52, moderate" / "fine particles 12 µg/m³, moderate".
    var spoken: String { "\(metric.plainName.lowercased()) \(text), \(level.label.lowercased())" }
}

/// One hour, with its chips and worst health levels worked out once.
private struct HealthLogHour: Identifiable {
    let snapshot: HourSnapshot
    let air: HealthLogReading?
    let water: HealthLogReading?
    /// Worst level across this hour's health readings, per kind. Nil when none were measured.
    let airWorst: EnvLevel?
    let waterWorst: EnvLevel?

    init(snapshot: HourSnapshot) {
        self.snapshot = snapshot
        func headline(_ kind: EnvKind) -> HealthLogReading? {
            EnvMetric.headlineOrder(kind).lazy
                .filter(\.healthLogIsHealthLimit)
                .compactMap { metric in snapshot.values[metric].map { HealthLogReading(metric: metric, value: $0) } }
                .first
        }
        func worst(_ kind: EnvKind) -> EnvLevel? {
            snapshot.values.filter { $0.key.kind == kind && $0.key.healthLogIsHealthLimit }
                .map { $0.key.level($0.value) }.max()
        }
        air = headline(.air)
        water = headline(.water)
        airWorst = worst(.air)
        waterWorst = worst(.water)
    }

    var id: Date { snapshot.time }
    var time: Date { snapshot.time }
    var aqi: Double? { snapshot.values[.aqi] }
    var wqi: Double? { snapshot.values[.wqi] }

    func reading(_ kind: EnvKind) -> HealthLogReading? { kind == .air ? air : water }
    func worst(_ kind: EnvKind) -> EnvLevel? { kind == .air ? airWorst : waterWorst }
    func isOver(_ kind: EnvKind) -> Bool { (worst(kind) ?? .good) >= healthLogLimit }

    func has(_ kinds: HealthLogKinds) -> Bool { kinds.shown.contains { reading($0) != nil } }
    func isOver(_ kinds: HealthLogKinds) -> Bool { kinds.shown.contains { isOver($0) } }

    /// Health readings of a kind measured this hour, in the contract's order.
    func metrics(_ kind: EnvKind) -> [EnvMetric] {
        EnvMetric.metrics(for: kind).filter { $0.healthLogIsHealthLimit && snapshot.values[$0] != nil }
    }

    /// Comfort and background readings of a kind measured this hour (humidity, temperature…).
    func comfortMetrics(_ kind: EnvKind) -> [EnvMetric] {
        EnvMetric.metrics(for: kind).filter { !$0.healthLogIsHealthLimit && snapshot.values[$0] != nil }
    }

    /// The reading that put this hour over the limit when the chips don't show it
    /// (e.g. fine particles high while AQI is moderate), so "over the limit" never looks unexplained.
    func hiddenCulprit(_ kinds: HealthLogKinds) -> (metric: EnvMetric, level: EnvLevel)? {
        var worst: (metric: EnvMetric, level: EnvLevel)?
        for kind in kinds.shown {
            let shown = reading(kind)
            for metric in metrics(kind) where metric != shown?.metric {
                guard let value = snapshot.values[metric] else { continue }
                let level = metric.level(value)
                if level >= healthLogLimit, level > (shown?.level ?? .good), level > (worst?.level ?? .good) {
                    worst = (metric, level)
                }
            }
        }
        return worst
    }
}

private struct HealthLogDay: Identifiable {
    let day: Date
    var hours: [HealthLogHour]
    var id: Date { day }

    var worstAQI: Double? { hours.compactMap(\.aqi).max() }
    var worstWQI: Double? { hours.compactMap(\.wqi).min() }

    /// This day with only the hours the filters let through, or nil when none do.
    func filtered(_ filter: HealthLogFilter, _ kinds: HealthLogKinds) -> HealthLogDay? {
        let kept = hours.filter { $0.has(kinds) && (filter == .all || $0.isOver(kinds)) }
        return kept.isEmpty ? nil : HealthLogDay(day: day, hours: kept)
    }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

private extension EnvLevel {
    /// One word that describes a reading, for chips and captions ("Cloudiness: high").
    /// The full label ("Unhealthy for sensitive groups") is for VoiceOver and the expanded rows.
    var logShortLabel: String {
        switch self {
        case .good: "Good"
        case .moderate: "Moderate"
        case .sensitive: "High"
        case .unhealthy: "Unhealthy"
        case .hazardous: "Hazardous"
        }
    }
}

// MARK: - Views

/// "4 PM" where the clock is 12-hour, "16:00" where it's 24-hour.
private func healthLogHourText(_ time: Date) -> String {
    let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h a"
    return template.contains("a") ? time.formatted(.dateTime.hour()) : time.formatted(.dateTime.hour().minute())
}

/// Hours over the limit this week, one tile per kind, plus the Air / Water menu.
private struct HealthLogSummary: View {
    let days: [HealthLogDay]
    @Binding var kinds: HealthLogKinds
    @Binding var filter: HealthLogFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hours over the limit").font(.headline)
                    Text("Last 7 days").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                Menu {
                    Picker("Show readings", selection: $kinds) {
                        ForEach(HealthLogKinds.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(kinds.label)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
                .accessibilityLabel("Show readings: \(kinds.label)")
            }
            HStack(spacing: 10) {
                ForEach(kinds.shown) { kind in tile(kind) }
            }
            Picker("Show", selection: $filter) {
                Text("All hours").tag(HealthLogFilter.all)
                Text("Over the limit").tag(HealthLogFilter.over)
            }
            .pickerStyle(.segmented)
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
    }

    private func tile(_ kind: EnvKind) -> some View {
        let measured = days.reduce(0) { $0 + $1.hours.filter { $0.worst(kind) != nil }.count }
        let over = days.reduce(0) { $0 + $1.hours.filter { $0.isOver(kind) }.count }
        return VStack(alignment: .leading, spacing: 6) {
            HealthLogKindLabel(kind: kind)
            if measured == 0 {
                // No data is not the same as clean: no number, no bar.
                Text("No sensors nearby")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(over)")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    Text("of \(measured) h")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: Double(over) / Double(measured))
                    .tint(over == 0 ? Brand.teal : Brand.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(measured == 0 ? "\(kind.label): no sensors nearby"
                            : "\(kind.label): \(over) of \(measured) hours over the limit")
    }
}

private struct HealthLogDayHeader: View {
    let day: HealthLogDay
    let kinds: HealthLogKinds

    var body: some View {
        HStack(spacing: 8) {
            Text(day.title)
            Spacer(minLength: 4)
            if let worst = worst {
                Text("Worst").font(.caption).foregroundStyle(.secondary)
                HealthLogChip(kind: worst.kind, value: worst.text, level: worst.level, compact: true)
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isHeader)
    }

    private var worst: (kind: EnvKind, text: String, level: EnvLevel)? {
        if kinds.shows(.air), let aqi = day.worstAQI {
            return (.air, EnvMetric.aqi.format(aqi), EnvMetric.aqi.level(aqi))
        }
        if kinds.shows(.water), let wqi = day.worstWQI {
            return (.water, EnvMetric.wqi.format(wqi), EnvMetric.wqi.level(wqi))
        }
        return nil
    }

    private var accessibilityText: String {
        guard let worst else { return day.title }
        let name = worst.kind == .air ? "air quality" : "water quality"
        return "\(day.title), worst \(name) \(worst.text), \(worst.level.label.lowercased())"
    }
}

/// An index value with its level: icon, number, and the level word, tinted by level.
private struct HealthLogChip: View {
    let kind: EnvKind
    let value: String?
    let level: EnvLevel
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(level.color)
            if let value {
                Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(.primary)
            }
            Text(level.logShortLabel).foregroundStyle(.secondary)
        }
        .font(compact ? .caption2 : .caption)
        .lineLimit(1)
        .padding(.horizontal, compact ? 7 : 8)
        .padding(.vertical, compact ? 3 : 4)
        .background(level.color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(level.color.opacity(0.35), lineWidth: 0.5))
    }
}

/// One hour that expands in place to every reading, grouped Air / Water, plus what to do.
private struct HealthLogRow: View {
    let hour: HealthLogHour
    let kinds: HealthLogKinds
    @State private var expanded = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                summary.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint(expanded ? "Collapses details" : "Shows every reading for this hour")

            if expanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Keep the separator full width; the tip's label would otherwise pull it in.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    // MARK: Collapsed

    private var summary: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(healthLogHourText(hour.time))
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                if isNow {
                    Text("Now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.teal)
                }
                if let culprit = hour.hiddenCulprit(kinds) {
                    Text("\(culprit.metric.plainName): \(culprit.level.logShortLabel.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { chips }
                VStack(alignment: .trailing, spacing: 4) { chips }
            }
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(kinds.shown) { kind in
            if let reading = hour.reading(kind) {
                HealthLogChip(kind: kind, value: reading.text, level: reading.level)
            }
        }
    }

    private var isNow: Bool {
        Date.now.timeIntervalSince(hour.time) < 3600 && Date.now >= hour.time
    }

    // MARK: Expanded

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(kinds.shown.filter { !hour.metrics($0).isEmpty || !hour.comfortMetrics($0).isEmpty }) { kind in
                group(kind)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tips) { TipRow(tip: $0) }
            }
        }
        .padding(.bottom, 4)
    }

    private func group(_ kind: EnvKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HealthLogKindLabel(kind: kind)
                .accessibilityAddTraits(.isHeader)
            if typeSize.isAccessibilitySize {
                ForEach(hour.metrics(kind)) { metric in stackedMetric(metric) }
            } else if !hour.metrics(kind).isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(hour.metrics(kind)) { metric in gridMetric(metric) }
                }
            }
            comfortLine(kind)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func gridMetric(_ metric: EnvMetric) -> some View {
        let value = hour.snapshot.values[metric] ?? 0
        let level = metric.level(value)
        return GridRow(alignment: .firstTextBaseline) {
            Text(metric.plainName)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(metric.format(value))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .gridColumnAlignment(.trailing)
            HealthLogLevelTag(level: level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.plainName), \(metric.format(value)), \(level.label.lowercased())")
    }

    private func stackedMetric(_ metric: EnvMetric) -> some View {
        let value = hour.snapshot.values[metric] ?? 0
        let level = metric.level(value)
        return VStack(alignment: .leading, spacing: 2) {
            Text(metric.plainName).font(.subheadline)
            HStack(spacing: 8) {
                Text(metric.format(value)).font(.subheadline.weight(.semibold).monospacedDigit())
                HealthLogLevelTag(level: level, full: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.plainName), \(metric.format(value)), \(level.label.lowercased())")
    }

    /// Comfort and background readings (humidity, temperature, minerals) have no health limit,
    /// so they get one plain line with no level color.
    @ViewBuilder
    private func comfortLine(_ kind: EnvKind) -> some View {
        let comfort = hour.comfortMetrics(kind)
        if !comfort.isEmpty {
            let text = comfort.map { "\($0.plainName) \($0.format(hour.snapshot.values[$0] ?? 0))" }
                .joined(separator: " · ")
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(text). Comfort readings, no health limit")
        }
    }

    /// One action per finding: the air tip for this hour's AQI, and a water tip only when it
    /// says what to do (the store's "water is good" line would contradict a Moderate chip).
    private var tips: [Insights.Tip] {
        var tips: [Insights.Tip] = []
        if kinds.shows(.air), let aqi = hour.aqi { tips.append(HealthAdvice.air(aqi: aqi)) }
        let turbidity = hour.snapshot.values[.turbidity]
        // Raw sensors report cloudiness without an index; score only the cloudiness then.
        if kinds.shows(.water), let wqi = hour.wqi ?? turbidity.map({ _ in 100 }) {
            let tip = HealthAdvice.water(wqi: wqi, turbidity: turbidity)
            if tip.kind == .warning { tips.append(tip) }
        }
        return tips
    }

    // MARK: Accessibility

    /// "4 PM, air quality 52, moderate; water quality 88, good".
    private var accessibilityText: String {
        let parts = kinds.shown.compactMap { hour.reading($0)?.spoken }
        var text = healthLogHourText(hour.time)
        if isNow { text += ", now" }
        if !parts.isEmpty { text += ", " + parts.joined(separator: "; ") }
        if let culprit = hour.hiddenCulprit(kinds) {
            text += ". \(culprit.metric.plainName) \(culprit.level.label.lowercased())"
        }
        if hour.isOver(kinds) { text += ". Over the limit" }
        return text
    }
}

/// "Air" / "Water" with its symbol, tighter than a Label at caption size.
private struct HealthLogKindLabel: View {
    let kind: EnvKind

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.symbol)
            Text(kind.label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// Level dot and word, for the expanded readings. `full` spells out the level
/// ("Unhealthy for sensitive groups") where a row has the width for it.
private struct HealthLogLevelTag: View {
    let level: EnvLevel
    var full = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(level.color).frame(width: 8, height: 8)
            Text(full ? level.label : level.logShortLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(full ? nil : 1)
                .fixedSize(horizontal: false, vertical: full)
        }
    }
}

private struct HealthLogProgress: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
