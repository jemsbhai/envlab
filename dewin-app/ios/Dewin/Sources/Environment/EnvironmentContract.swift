import CoreLocation
import Foundation
import SwiftUI

// Wire types for the air & water side. See docs/BACKEND_CONTRACT.md, "Environment".

/// Producer: where this phone is. The `location` event, emitted with no ack.
/// Rounded to about 1 km: the server only needs the area to collect sensor data for.
struct LocationPing: Codable, Sendable {
    static let schema = "dewin.location/1"
    var schema = LocationPing.schema
    var clientId: String
    var lat: Double
    var lon: Double
    var accuracyM: Double
    var recordedAt: Date

    init(clientId: String, coordinate: CLLocationCoordinate2D, accuracy: Double, recordedAt: Date = .now) {
        self.clientId = clientId
        lat = (coordinate.latitude * 100).rounded() / 100
        lon = (coordinate.longitude * 100).rounded() / 100
        accuracyM = max(accuracy, 1_000)
        self.recordedAt = recordedAt
    }
}

/// Consumer API: the `env:query` event; the server answers in the ack with an `EnvSeries`.
struct EnvQuery: Codable, Sendable, Equatable {
    static let event = "env:query"
    static let schema = "dewin.env.query/1"

    struct BBox: Codable, Sendable, Equatable {
        var minLat: Double
        var minLon: Double
        var maxLat: Double
        var maxLon: Double
    }

    var schema = EnvQuery.schema
    var clientId: String
    var bbox: BBox
    var from: Date
    var to: Date
    /// Bucket size the server should average readings into.
    var stepMinutes: Int
    var kinds: [EnvKind]
}

enum EnvKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case air, water
    var id: String { rawValue }
    var label: String { self == .air ? "Air" : "Water" }
    var symbol: String { self == .air ? "aqi.medium" : "drop.fill" }
}

/// Reply to `EnvQuery`: stations in the box, each with readings over the time range.
struct EnvSeries: Codable, Sendable {
    static let schema = "dewin.env.series/1"

    struct Station: Codable, Sendable, Identifiable, Hashable {
        var id: String
        var kind: EnvKind
        var name: String?
        var lat: Double
        var lon: Double
        /// Where the data came from, e.g. "OpenAQ", "USGS".
        var source: String?
        /// Oldest first.
        var readings: [Reading]

        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

        /// The latest reading at or before `time` (within `maxAge`), else nil. Binary search:
        /// `readings` is oldest first.
        func reading(at time: Date, maxAge: TimeInterval = 3 * 3600) -> Reading? {
            var low = 0, high = readings.count
            while low < high {
                let mid = (low + high) / 2
                if readings[mid].t <= time { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { return nil }
            let reading = readings[low - 1]
            return time.timeIntervalSince(reading.t) <= maxAge ? reading : nil
        }
    }

    struct Reading: Codable, Sendable, Hashable {
        var t: Date
        /// Metric key → value, keys from `EnvMetric`. Missing means not measured.
        var values: [String: Double]
    }

    var schema: String?
    var from: Date?
    var to: Date?
    var stepMinutes: Int?
    var stations: [Station]
    var error: String?
}

enum EnvError: LocalizedError {
    case emptyReply
    case server(String)

    var errorDescription: String? {
        switch self {
        case .emptyReply: "The server sent an empty reply."
        case let .server(message): message
        }
    }
}

/// The metrics the map can color by. Keys match `Reading.values`.
enum EnvMetric: String, CaseIterable, Identifiable, Sendable {
    // Air
    case aqi, pm25, pm10, o3, no2, co2, humidity, airTemperature
    // Water
    case wqi, ph, turbidity, dissolvedOxygen, temperature, conductivity, tds

    var id: String { rawValue }
    var kind: EnvKind {
        [.aqi, .pm25, .pm10, .o3, .no2, .co2, .humidity, .airTemperature].contains(self) ? .air : .water
    }

    static func metrics(for kind: EnvKind) -> [EnvMetric] { allCases.filter { $0.kind == kind } }

    var label: String {
        switch self {
        case .aqi: "AQI"
        case .pm25: "PM2.5"
        case .pm10: "PM10"
        case .o3: "Ozone"
        case .no2: "NO₂"
        case .co2: "CO₂"
        case .humidity: "Humidity"
        case .airTemperature: "Air temp"
        case .wqi: "Quality"
        case .ph: "pH"
        case .turbidity: "Turbidity"
        case .dissolvedOxygen: "Oxygen"
        case .temperature: "Temp"
        case .conductivity: "Conductivity"
        case .tds: "TDS"
        }
    }

    var unit: String {
        switch self {
        case .aqi: ""
        case .pm25, .pm10: "µg/m³"
        case .o3, .no2: "ppb"
        case .co2: "ppm"
        case .humidity: "%"
        case .airTemperature: "°C"
        case .wqi: "/100"
        case .ph: ""
        case .turbidity: "NTU"
        case .dissolvedOxygen: "mg/L"
        case .temperature: "°C"
        case .conductivity: "µS/cm"
        case .tds: "ppm"
        }
    }

    func format(_ value: Double) -> String {
        let number = self == .ph ? value.formatted(.number.precision(.fractionLength(1)))
            : value < 10 && self != .aqi && self != .wqi ? value.formatted(.number.precision(.fractionLength(0...1)))
            : Int(value.rounded()).formatted()
        return unit.isEmpty || unit == "/100" ? number : "\(number) \(unit)"
    }

    /// Health level for a value, so the map can color it.
    func level(_ value: Double) -> EnvLevel {
        switch self {
        case .aqi: // US EPA AQI categories
            value <= 50 ? .good : value <= 100 ? .moderate : value <= 150 ? .sensitive : value <= 200 ? .unhealthy : .hazardous
        case .pm25: // µg/m³, 24 h breakpoints (EPA 2024)
            value <= 9 ? .good : value <= 35.4 ? .moderate : value <= 55.4 ? .sensitive : value <= 125.4 ? .unhealthy : .hazardous
        case .pm10:
            value <= 54 ? .good : value <= 154 ? .moderate : value <= 254 ? .sensitive : value <= 354 ? .unhealthy : .hazardous
        case .o3: // ppb, 8 h
            value <= 54 ? .good : value <= 70 ? .moderate : value <= 85 ? .sensitive : value <= 105 ? .unhealthy : .hazardous
        case .no2: // ppb, 1 h
            value <= 53 ? .good : value <= 100 ? .moderate : value <= 360 ? .sensitive : value <= 649 ? .unhealthy : .hazardous
        case .wqi: // 0–100, higher is better
            value >= 90 ? .good : value >= 70 ? .moderate : value >= 50 ? .sensitive : value >= 25 ? .unhealthy : .hazardous
        case .ph: // EPA drinking water secondary standard 6.5–8.5
            (6.5...8.5).contains(value) ? .good : (6...9).contains(value) ? .moderate : .unhealthy
        case .turbidity:
            value <= 1 ? .good : value <= 5 ? .moderate : value <= 25 ? .sensitive : value <= 100 ? .unhealthy : .hazardous
        case .dissolvedOxygen: // mg/L, aquatic life
            value >= 7 ? .good : value >= 5 ? .moderate : value >= 3 ? .unhealthy : .hazardous
        case .temperature:
            value <= 20 ? .good : value <= 25 ? .moderate : value <= 30 ? .sensitive : .unhealthy
        case .co2: // ppm indoors; ventilation guidance (ASHRAE ~1,000 ppm)
            value <= 800 ? .good : value <= 1_000 ? .moderate : value <= 1_500 ? .sensitive : value <= 2_500 ? .unhealthy : .hazardous
        case .humidity: // % relative humidity; comfort, not a health limit
            (30...60).contains(value) ? .good : (25...70).contains(value) ? .moderate : .sensitive
        case .airTemperature: // °C; comfort
            (18...27).contains(value) ? .good : (10...32).contains(value) ? .moderate : .sensitive
        case .conductivity: // µS/cm; typical drinking water 50–800
            value <= 800 ? .good : value <= 1_500 ? .moderate : value <= 2_500 ? .sensitive : .unhealthy
        case .tds: // ppm; EPA secondary standard 500 mg/L
            value <= 300 ? .good : value <= 500 ? .moderate : value <= 1_000 ? .sensitive : .unhealthy
        }
    }
}

enum EnvLevel: Int, Comparable, Sendable {
    case good, moderate, sensitive, unhealthy, hazardous

    static func < (a: EnvLevel, b: EnvLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .good: "Good"
        case .moderate: "Moderate"
        case .sensitive: "Unhealthy for sensitive groups"
        case .unhealthy: "Unhealthy"
        case .hazardous: "Hazardous"
        }
    }

    var color: Color {
        switch self {
        case .good: Color(red: 0.13, green: 0.77, blue: 0.37)
        case .moderate: Color(red: 0.98, green: 0.80, blue: 0.08)
        case .sensitive: Color(red: 0.98, green: 0.55, blue: 0.10)
        case .unhealthy: Color(red: 0.90, green: 0.20, blue: 0.20)
        case .hazardous: Color(red: 0.55, green: 0.15, blue: 0.55)
        }
    }
}
