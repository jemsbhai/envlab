import Foundation
import MapKit
import Observation

/// Consumer side of air & water: asks the server for readings in the visible map area over a
/// time range (`env:query` with a Socket.IO ack), and holds the time cursor the scrubber moves.
@Observable
@MainActor
final class EnvironmentStore {
    enum Range: String, CaseIterable, Identifiable {
        case day, threeDays, week
        var id: String { rawValue }
        var label: String { switch self { case .day: "24 h"; case .threeDays: "3 days"; case .week: "7 days" } }
        var duration: TimeInterval { switch self { case .day: 86_400; case .threeDays: 3 * 86_400; case .week: 7 * 86_400 } }
        var stepMinutes: Int { switch self { case .day: 60; case .threeDays: 60; case .week: 180 } }
    }

    var kind: EnvKind = .air { didSet { if kind != oldValue { metric = EnvMetric.metrics(for: kind)[0]; reload() } } }
    var metric: EnvMetric = .aqi
    var range: Range = .day { didSet { if range != oldValue { reload() } } }

    private(set) var stations: [EnvSeries.Station] = []
    /// One entry per time bucket, oldest first; the scrubber moves through these.
    private(set) var frames: [Date] = []
    var frameIndex = 0
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var lastLoaded: Date?
    private(set) var isPlaying = false

    var currentTime: Date? { frames.indices.contains(frameIndex) ? frames[frameIndex] : nil }

    @ObservationIgnored private let query: (EnvQuery) async throws -> EnvSeries
    @ObservationIgnored private var region: MKCoordinateRegion?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?

    /// `query` answers an `env:query`: the mock backend's stations, or live envlab exposures.
    init(query: @escaping (EnvQuery) async throws -> EnvSeries) {
        self.query = query
    }

    /// The map moved. Waits for it to settle, then loads that area.
    func regionChanged(_ region: MKCoordinateRegion) {
        self.region = region
        load(debounce: .milliseconds(450))
    }

    func reload() { load(debounce: .zero) }

    private func load(debounce: Duration) {
        guard let region else { return }
        loadTask?.cancel()
        loadTask = Task {
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            let now = Date()
            let query = EnvQuery(
                clientId: BackendSettings.clientID,
                bbox: .init(minLat: region.center.latitude - region.span.latitudeDelta / 2,
                            minLon: region.center.longitude - region.span.longitudeDelta / 2,
                            maxLat: region.center.latitude + region.span.latitudeDelta / 2,
                            maxLon: region.center.longitude + region.span.longitudeDelta / 2),
                from: now.addingTimeInterval(-range.duration), to: now,
                stepMinutes: range.stepMinutes, kinds: [kind]
            )
            isLoading = true
            defer { isLoading = false }
            do {
                let series = try await self.query(query)
                guard !Task.isCancelled else { return }
                apply(series, query: query)
                error = nil
                lastLoaded = .now
                NSLog("[Env] %d %@ stations, %d frames", stations.count, kind.rawValue, frames.count)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                NSLog("[Env] query failed: %@", String(describing: error))
            }
        }
    }

    private func apply(_ series: EnvSeries, query: EnvQuery) {
        let wasAtEnd = frameIndex >= frames.count - 1
        let previousTime = currentTime
        stations = series.stations.filter { $0.kind == kind }
        // Live sensors report what they have (often PM2.5 and CO₂, no AQI): show a metric that has data.
        let measured = Set(stations.flatMap { $0.readings.flatMap(\.values.keys) })
        if !measured.contains(metric.rawValue),
           let available = EnvMetric.metrics(for: kind).first(where: { measured.contains($0.rawValue) }) {
            metric = available
        }
        let step = TimeInterval((series.stepMinutes ?? query.stepMinutes) * 60)
        let start = ((series.from ?? query.from).timeIntervalSince1970 / step).rounded(.up) * step
        let end = (series.to ?? query.to).timeIntervalSince1970
        frames = stride(from: start, through: end, by: step).map(Date.init(timeIntervalSince1970:))
        // The last frame is "now", not the top of the hour: readings from this hour come after 16:00 at 16:50.
        if let last = frames.last?.timeIntervalSince1970, end - last > 60 {
            frames.append(Date(timeIntervalSince1970: end))
        }
        // Stay where the user was scrubbing; otherwise show the latest.
        if !wasAtEnd, let previousTime, let index = frames.lastIndex(where: { $0 <= previousTime }) {
            frameIndex = index
        } else {
            frameIndex = max(frames.count - 1, 0)
        }
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying { stopPlaying() } else { play() }
    }

    func play() {
        guard frames.count > 1 else { return }
        if frameIndex >= frames.count - 1 { frameIndex = 0 }
        isPlaying = true
        playTask = Task {
            while !Task.isCancelled, frameIndex < frames.count - 1 {
                try? await Task.sleep(for: .milliseconds(frames.count > 60 ? 120 : 250))
                guard !Task.isCancelled else { return }
                frameIndex += 1
            }
            isPlaying = false
        }
    }

    func stopPlaying() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    // MARK: Summaries

    /// The scrubber is on the last frame: "now".
    var isAtLatest: Bool { !frames.isEmpty && frameIndex >= frames.count - 1 }

    /// At "now", a pin shows its station's newest reading up to this old (sensors report every few
    /// minutes, simulated ones less often). Older than that, the station has gone quiet.
    static let latestMaxAge: TimeInterval = 24 * 3600
    /// A latest reading older than this is drawn dimmed.
    static let staleAge: TimeInterval = 3600

    /// The reading a station shows on frame `index`: its newest at "now", else the one in effect at
    /// that frame (within 3 buckets).
    func reading(for station: EnvSeries.Station, frame index: Int? = nil, now: Date = .now) -> EnvSeries.Reading? {
        let index = index ?? frameIndex
        guard frames.indices.contains(index) else { return nil }
        if index == frames.count - 1 {
            // Newest, even if a sensor's clock runs a little ahead of the phone's.
            guard let latest = station.readings.last, now.timeIntervalSince(latest.t) <= Self.latestMaxAge else { return nil }
            return latest
        }
        return station.reading(at: frames[index], maxAge: TimeInterval(range.stepMinutes * 60) * 3)
    }

    /// The value a station shows at the current time, for the selected metric.
    func value(for station: EnvSeries.Station) -> Double? {
        reading(for: station)?.values[metric.rawValue]
    }

    /// What a station's pin shows: the selected metric, or when the station doesn't measure it, the
    /// best metric it does (so a station with data never shows "–").
    func pin(for station: EnvSeries.Station, now: Date = .now) -> StationPinValue? {
        guard let reading = reading(for: station, now: now) else { return nil }
        let shown: (metric: EnvMetric, value: Double)? = reading.values[metric.rawValue].map { (metric, $0) }
            ?? EnvMetric.headline(station.kind, in: reading.values)
            ?? EnvMetric.metrics(for: station.kind).lazy.compactMap { metric in reading.values[metric.rawValue].map { (metric, $0) } }.first
        guard let shown else { return nil }
        return StationPinValue(metric: shown.metric, value: shown.value, time: reading.t,
                               isFallback: shown.metric != metric,
                               isStale: now.timeIntervalSince(reading.t) > Self.staleAge)
    }

    /// The newest reading time among visible stations, for "updated 2 min ago".
    var newestReading: Date? {
        stations.compactMap { reading(for: $0)?.t }.max()
    }

    /// Worst level among visible stations right now, for the headline.
    var worst: (station: EnvSeries.Station, value: Double)? {
        stations.compactMap { station in value(for: station).map { (station, $0) } }
            .max { metric.level($0.1) < metric.level($1.1) || (metric.level($0.1) == metric.level($1.1) && severity($0.1) < severity($1.1)) }
    }

    /// Larger is worse, for metrics where lower is worse.
    private func severity(_ value: Double) -> Double {
        [.wqi, .dissolvedOxygen].contains(metric) ? -value : value
    }
}

/// What one map pin shows.
struct StationPinValue: Equatable {
    let metric: EnvMetric
    let value: Double
    /// When the reading was measured.
    let time: Date
    /// The station doesn't measure the selected metric; this is the best one it does.
    let isFallback: Bool
    /// The newest reading is over an hour old.
    let isStale: Bool

    /// Temperature and humidity are context, not a verdict: no good/bad color.
    var level: EnvLevel? { metric.isAssessment ? metric.level(value) : nil }
}
