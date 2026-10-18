import CoreLocation
import Foundation
import Observation

/// Air and water "where you are": the last 7 days of readings around the phone, blended into
/// one value per hour for your area. Feeds Health › Today, Week and Log, and Home.
///
/// Uses the same `env:query` API as the map, with a fixed box (about ±9 km) around the
/// phone's last location, hourly buckets, both kinds.
@Observable
@MainActor
final class NearbyHealthStore {
    /// Half-size of the box queried around the phone, in degrees (~9 km north–south).
    static let radiusDegrees = 0.08
    /// Stations farther than this don't count toward "your area".
    static let maxDistanceKm = 15.0
    /// When there's no location yet, nothing is loaded and views show a prompt.

    private(set) var series: EnvSeries?
    private(set) var center: CLLocationCoordinate2D?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var lastLoaded: Date?

    @ObservationIgnored private let query: (EnvQuery) async throws -> EnvSeries
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// `query` answers an `env:query`: the mock backend's stations, or live envlab exposures.
    init(query: @escaping (EnvQuery) async throws -> EnvSeries) {
        self.query = query
    }

    /// Loads (or reloads) the week around `coordinate`. Skips if the same area loaded in the last 10 minutes,
    /// unless `force`.
    func refresh(around coordinate: CLLocationCoordinate2D, force: Bool = false) {
        if !force, let center, let lastLoaded, Date().timeIntervalSince(lastLoaded) < 600,
           CLLocation(latitude: center.latitude, longitude: center.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < 2_000 {
            return
        }
        loadTask?.cancel()
        loadTask = Task {
            let now = Date()
            let query = EnvQuery(
                clientId: BackendSettings.clientID,
                bbox: .init(minLat: coordinate.latitude - Self.radiusDegrees, minLon: coordinate.longitude - Self.radiusDegrees,
                            maxLat: coordinate.latitude + Self.radiusDegrees, maxLon: coordinate.longitude + Self.radiusDegrees),
                from: Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: now)) ?? now,
                to: now, stepMinutes: 60, kinds: [.air, .water]
            )
            isLoading = true
            defer { isLoading = false }
            do {
                let result = try await self.query(query)
                guard !Task.isCancelled else { return }
                series = result
                center = coordinate
                error = nil
                lastLoaded = .now
                NSLog("[Health] %d stations near %.2f,%.2f", result.stations.count, coordinate.latitude, coordinate.longitude)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                NSLog("[Health] load failed: %@", String(describing: error))
            }
        }
    }

    // MARK: Stations near you

    /// Stations of a kind within `maxDistanceKm`, nearest first.
    func stations(_ kind: EnvKind) -> [(station: EnvSeries.Station, distanceKm: Double)] {
        guard let center, let series else { return [] }
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return series.stations
            .filter { $0.kind == kind }
            .map { ($0, CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: here) / 1000) }
            .filter { $0.1 <= Self.maxDistanceKm }
            .sorted { $0.1 < $1.1 }
    }

    /// The nearest station with a reading in the last 3 hours, and that reading.
    func nearest(_ kind: EnvKind, now: Date = .now) -> (station: EnvSeries.Station, reading: EnvSeries.Reading, distanceKm: Double)? {
        for (station, distance) in stations(kind) {
            if let reading = station.reading(at: now) { return (station, reading, distance) }
        }
        return nil
    }

    // MARK: Your area, blended

    /// Your area's value for `metric` at `time`: an inverse-distance-weighted average over nearby
    /// stations that have a reading for that hour. Nil when none do.
    func areaValue(_ metric: EnvMetric, at time: Date) -> Double? {
        var weighted = 0.0, weights = 0.0
        for (station, distance) in stations(metric.kind) {
            guard let value = station.reading(at: time, maxAge: 2 * 3600)?.values[metric.rawValue] else { continue }
            let weight = 1 / (distance * distance + 0.25)
            weighted += value * weight
            weights += weight
        }
        return weights > 0 ? weighted / weights : nil
    }

    /// Hourly area values for one calendar day (up to now), oldest first.
    func hourly(_ metric: EnvMetric, on day: Date = .now, now: Date = .now, calendar: Calendar = .current) -> [HourValue] {
        let start = calendar.startOfDay(for: day)
        return (0..<24).compactMap { hour -> HourValue? in
            guard let time = calendar.date(byAdding: .hour, value: hour, to: start), time <= now,
                  let value = areaValue(metric, at: time) else { return nil }
            return HourValue(time: time, value: value)
        }
    }

    /// One summary per day for the last 7 days including today, oldest first. Days with no data are included
    /// with `hours == 0` so charts keep their shape.
    func days(_ metric: EnvMetric, now: Date = .now, calendar: Calendar = .current) -> [HealthDay] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().compactMap { offset -> HealthDay? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return HealthDay(day: day, metric: metric, hours: hourly(metric, on: day, now: now, calendar: calendar))
        }
    }

    /// Every hour of the last 7 days with any reading, newest first, with all metrics of both kinds.
    /// Feeds Health › Log.
    func log(now: Date = .now, calendar: Calendar = .current) -> [HourSnapshot] {
        let start = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) ?? now
        var snapshots: [HourSnapshot] = []
        var time = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        while time >= start {
            var values: [EnvMetric: Double] = [:]
            for metric in EnvMetric.allCases {
                if let value = areaValue(metric, at: time) { values[metric] = value }
            }
            if !values.isEmpty { snapshots.append(HourSnapshot(time: time, values: values)) }
            time = time.addingTimeInterval(-3600)
        }
        return snapshots
    }
}

struct HourValue: Identifiable, Hashable {
    let time: Date
    let value: Double
    var id: Date { time }
}

/// One day of one metric in your area.
struct HealthDay: Identifiable {
    let day: Date
    let metric: EnvMetric
    let hours: [HourValue]

    var id: Date { day }
    var hasData: Bool { !hours.isEmpty }
    var average: Double? { hours.isEmpty ? nil : hours.map(\.value).reduce(0, +) / Double(hours.count) }
    /// The worst hour: highest value, or lowest for metrics where lower is worse (water quality, oxygen).
    var worst: HourValue? {
        metric.lowerIsWorse ? hours.min { $0.value < $1.value } : hours.max { $0.value < $1.value }
    }
    var best: HourValue? {
        metric.lowerIsWorse ? hours.max { $0.value < $1.value } : hours.min { $0.value < $1.value }
    }
    /// Hours that were worse than "good".
    var hoursOverGood: Int { hours.filter { metric.level($0.value) > .good }.count }
    var worstLevel: EnvLevel? { worst.map { metric.level($0.value) } }
}

/// Everything known about your area for one hour.
struct HourSnapshot: Identifiable {
    let time: Date
    let values: [EnvMetric: Double]
    var id: Date { time }

    /// Worst level across the metrics measured this hour, for a kind.
    func worstLevel(_ kind: EnvKind) -> EnvLevel? {
        values.filter { $0.key.kind == kind }.map { $0.key.level($0.value) }.max()
    }
}

extension EnvMetric {
    /// Water quality index and dissolved oxygen: a low value is the bad direction.
    var lowerIsWorse: Bool { self == .wqi || self == .dissolvedOxygen }

    /// Plain-language name for people, not scientists.
    var plainName: String {
        switch self {
        case .aqi: "Air quality"
        case .pm25: "Fine particles"
        case .pm10: "Dust"
        case .o3: "Ozone"
        case .no2: "Traffic fumes (NO₂)"
        case .co2: "CO₂ (stuffiness)"
        case .humidity: "Humidity"
        case .airTemperature: "Air temperature"
        case .wqi: "Water quality"
        case .ph: "Acidity (pH)"
        case .turbidity: "Cloudiness"
        case .dissolvedOxygen: "Oxygen in water"
        case .temperature: "Water temperature"
        case .conductivity: "Conductivity (minerals)"
        case .tds: "Dissolved solids (TDS)"
        }
    }
}

/// One action per finding, never a lecture. Based on EPA AirNow activity guidance.
enum HealthAdvice {
    static func air(aqi: Double) -> Insights.Tip {
        switch EnvMetric.aqi.level(aqi) {
        case .good:
            .init(kind: .good, text: "Air is clean. Good time for a run or to open the windows.")
        case .moderate:
            .init(kind: .info, text: "If you're sensitive to air pollution, take it easier on long outdoor workouts.")
        case .sensitive:
            .init(kind: .warning, text: "Kids, older adults and anyone with asthma: keep outdoor exercise short today.")
        case .unhealthy:
            .init(kind: .warning, text: "Move workouts indoors and keep windows closed.")
        case .hazardous:
            .init(kind: .warning, text: "Stay inside with windows shut and run an air purifier if you have one.")
        }
    }

    static func water(wqi: Double, turbidity: Double?) -> Insights.Tip {
        if let turbidity, EnvMetric.turbidity.level(turbidity) >= .sensitive {
            return .init(kind: .warning, text: "Local water is cloudy. If your tap water looks cloudy, run it for 2 minutes first.")
        }
        switch EnvMetric.wqi.level(wqi) {
        case .good, .moderate:
            return .init(kind: .good, text: "Nearby water quality is good.")
        default:
            return .init(kind: .warning, text: "Nearby water quality is low. Skip swimming or wading in local streams today.")
        }
    }
}

extension EnvMetric {
    /// What to headline for a kind, best first. Live Dewin sensors report raw values (PM2.5, pH,
    /// turbidity…) and no AQI or water quality index; we show those rather than invent an index.
    /// Water temperature is never a headline: on its own it says nothing about water quality.
    static func headlineOrder(_ kind: EnvKind) -> [EnvMetric] {
        kind == .air ? [.aqi, .pm25, .pm10, .no2, .o3, .co2]
                     : [.wqi, .turbidity, .ph, .tds, .conductivity, .dissolvedOxygen]
    }

    /// The best headline metric present in `values`, and its value.
    static func headline(_ kind: EnvKind, in values: [EnvMetric: Double]) -> (metric: EnvMetric, value: Double)? {
        headlineOrder(kind).lazy.compactMap { metric in values[metric].map { (metric, $0) } }.first
    }

    static func headline(_ kind: EnvKind, in values: [String: Double]) -> (metric: EnvMetric, value: Double)? {
        headlineOrder(kind).lazy.compactMap { metric in values[metric.rawValue].map { (metric, $0) } }.first
    }
}

extension NearbyHealthStore {
    /// The metric Health headlines for a kind in your area: AQI / water quality index when measured,
    /// else the best raw metric the nearby sensors report. Nil when nothing is measured.
    func headlineMetric(_ kind: EnvKind) -> EnvMetric? {
        let measured = Set(stations(kind).flatMap { $0.station.readings.flatMap(\.values.keys) })
        return EnvMetric.headlineOrder(kind).first { measured.contains($0.rawValue) }
    }
}

extension EnvMetric {
    /// Whether a value carries a health verdict. Temperature and humidity are context: show the
    /// number, never "good"/"unhealthy" (envlab: "temperature alone is not a water-quality assessment").
    var isAssessment: Bool { ![.temperature, .airTemperature, .humidity].contains(self) }
}
