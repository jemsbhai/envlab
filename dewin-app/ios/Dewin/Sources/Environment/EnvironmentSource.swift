import Foundation

/// Where Health and the map get air & water readings. With the envlab gateway on, they come from
/// your own exposures: sensors the server matched to where you were. Otherwise the server
/// connection (or the on-device mock) answers `env:query` with stations.
@MainActor
struct EnvironmentSource {
    let pipeline: MealPipeline
    let exposures: ExposureStore

    func query(_ query: EnvQuery) async throws -> EnvSeries {
        guard EnvlabSettings.current.mode == .live else {
            return try await pipeline.currentBackend.queryEnvironment(query)
        }
        var series = exposures.series(from: query.from, to: query.to, kinds: Set(query.kinds))
        let box = query.bbox
        series.stations = series.stations.filter {
            (box.minLat...box.maxLat).contains($0.lat) && (box.minLon...box.maxLon).contains($0.lon)
        }
        series.stepMinutes = series.stepMinutes ?? query.stepMinutes
        return series
    }
}
