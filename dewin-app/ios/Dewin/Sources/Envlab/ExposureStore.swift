import Foundation
import Observation

/// Your exposures: what the envlab server matched to where you were, live (`exposure:update`) and
/// from history (`exposure:history`). Upserted by `exposureId`, oldest first, kept for 90 days and
/// saved to Application Support/Dewin/exposures.json, so Health and the map work offline.
///
/// `series(from:to:kinds:)` turns them into the `EnvSeries` the UI already draws.
@Observable
@MainActor
final class ExposureStore {
    static let retention: TimeInterval = 90 * 86_400

    /// Sorted by (measuredAt, exposureId), one per exposureId.
    private(set) var exposures: [Exposure] = []

    /// The newest exposure that found a sensor nearby.
    var lastMatched: Exposure? { exposures.last(where: \.isMatched) }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var ids: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "io.occh.dewin.envlab.exposures", qos: .utility)

    init(fileURL: URL = EnvlabFiles.url("exposures.json")) {
        self.fileURL = fileURL
        if let saved = EnvlabFiles.read([Exposure].self, from: fileURL) {
            let cutoff = Date().addingTimeInterval(-Self.retention)
            var byID: [String: Exposure] = [:]
            for exposure in saved where exposure.measuredAt >= cutoff { byID[exposure.exposureId] = exposure }
            exposures = byID.values.sorted(by: Self.isOrdered)
            ids = Set(byID.keys)
            NSLog("[Envlab] loaded %@ saved exposures", String(exposures.count))
        }
    }

    func upsert(_ exposure: Exposure) {
        upsert(contentsOf: CollectionOfOne(exposure))
    }

    /// Adds new exposures and replaces ones with the same `exposureId` (a later copy wins).
    func upsert(contentsOf incoming: some Sequence<Exposure>) {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let fresh = incoming.filter { $0.measuredAt >= cutoff }
        guard !fresh.isEmpty else { return }

        // Live updates: one new record, newer than everything held. Append it.
        if fresh.count == 1, let exposure = fresh.first, !ids.contains(exposure.exposureId),
           exposures.last.map({ Self.isOrdered($0, exposure) }) ?? true,
           exposures.first.map({ $0.measuredAt >= cutoff }) ?? true {
            exposures.append(exposure)
            ids.insert(exposure.exposureId)
            scheduleSave()
            return
        }

        var byID = Dictionary(exposures.map { ($0.exposureId, $0) }, uniquingKeysWith: { _, later in later })
        var changed = false
        for exposure in fresh where byID[exposure.exposureId] != exposure {
            byID[exposure.exposureId] = exposure
            changed = true
        }
        let expired = exposures.first.map { $0.measuredAt < cutoff } ?? false
        guard changed || expired else { return }
        exposures = byID.values.filter { $0.measuredAt >= cutoff }.sorted(by: Self.isOrdered)
        ids = Set(exposures.map(\.exposureId))
        scheduleSave()
    }

    /// Forgets every exposure (for example after deleting your data on the server).
    func removeAll() {
        exposures = []
        ids = []
        scheduleSave()
    }

    /// Exposures whose fix was taken in `from...to`, oldest first.
    func exposures(from: Date, to: Date) -> [Exposure] {
        guard from <= to else { return [] }
        var low = 0, high = exposures.count
        while low < high {
            let mid = (low + high) / 2
            if exposures[mid].measuredAt < from { low = mid + 1 } else { high = mid }
        }
        var result: [Exposure] = []
        for exposure in exposures[low...] {
            if exposure.measuredAt > to { break }
            result.append(exposure)
        }
        return result
    }

    // MARK: Map / Health adapter

    /// Matched exposures in `from...to` as stations: one per (device, medium), e.g. "pico-01:water",
    /// with one reading per exposure at the sensor's observed time. Unknown media and `invalid`
    /// readings are left out; `no_match` exposures add nothing (a gap, never a zero).
    func series(from: Date, to: Date, kinds: Set<EnvKind> = [.air, .water]) -> EnvSeries {
        struct Key: Hashable {
            var deviceId: String
            var medium: String
        }
        struct Station {
            var kind: EnvKind
            var name: String?
            var position: Exposure.Position
            var positionTime: Date
            var simulated = false
            var readings: [Date: [String: Double]] = [:]
        }

        var stations: [Key: Station] = [:]
        for exposure in exposures(from: from, to: to) where exposure.isMatched {
            for sensor in exposure.sensors {
                let time = sensor.observedAt ?? exposure.measuredAt
                let position = sensor.position ?? exposure.position
                let name = sensor.locationId.map(Self.displayName)
                var byMedium: [String: [String: Double]] = [:]
                for measurement in sensor.measurements where measurement.quality != "invalid" && measurement.value.isFinite {
                    let key = Self.metricKey(measurement.metric, medium: measurement.medium)
                    byMedium[measurement.medium, default: [:]][key] = measurement.value
                }
                for (medium, values) in byMedium {
                    guard let kind = EnvKind(rawValue: medium), kinds.contains(kind) else { continue }
                    let key = Key(deviceId: sensor.deviceId, medium: medium)
                    var station = stations[key] ?? Station(kind: kind, name: name, position: position, positionTime: time)
                    if time >= station.positionTime {
                        station.position = position
                        station.positionTime = time
                        station.name = name ?? station.name
                    }
                    station.simulated = station.simulated || sensor.isSimulated
                    // Same time, same station: merge, the later exposure wins.
                    station.readings[time, default: [:]].merge(values) { _, later in later }
                    stations[key] = station
                }
            }
        }

        let result = stations.map { key, station in
            EnvSeries.Station(
                id: "\(key.deviceId):\(key.medium)",
                kind: station.kind,
                name: station.name ?? key.deviceId,
                lat: station.position.latitude,
                lon: station.position.longitude,
                source: station.simulated ? "Simulated" : "Dewin sensor",
                readings: station.readings.map { EnvSeries.Reading(t: $0.key, values: $0.value) }.sorted { $0.t < $1.t }
            )
        }
        return EnvSeries(schema: EnvSeries.schema, from: from, to: to, stepMinutes: nil,
                         stations: result.sorted { $0.id < $1.id }, error: nil)
    }

    /// API metric name → `EnvMetric` key. Unknown metrics keep their own name.
    static func metricKey(_ metric: String, medium: String) -> String {
        switch metric {
        case "pm2_5": "pm25"
        case "temperature": medium == "air" ? "airTemperature" : "temperature"
        default: metric // pm10, o3, no2, co2, humidity, ph, turbidity, conductivity, tds, …
        }
    }

    /// "demo-school" → "Demo school".
    static func displayName(_ locationId: String) -> String {
        let words = locationId.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return locationId }
        return first.uppercased() + words.dropFirst()
    }

    private static func isOrdered(_ a: Exposure, _ b: Exposure) -> Bool {
        a.measuredAt != b.measuredAt ? a.measuredAt < b.measuredAt : a.exposureId < b.exposureId
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes now instead of after the one-second debounce.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = exposures
        let url = fileURL
        ioQueue.async { EnvlabFiles.write(snapshot, to: url) }
    }
}

/// Files under Application Support/Dewin/.
enum EnvlabFiles {
    static func url(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Dewin", isDirectory: true).appendingPathComponent(name)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try EnvlabCoding.decoder.decode(type, from: data)
        } catch {
            NSLog("[Envlab] couldn't read %@: %@", url.lastPathComponent, String(describing: error))
            return nil
        }
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try EnvlabCoding.encoder.encode(value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[Envlab] couldn't save %@: %@", url.lastPathComponent, String(describing: error))
        }
    }
}
