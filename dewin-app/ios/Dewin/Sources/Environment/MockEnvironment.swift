import Foundation

/// Plausible air and water stations around wherever the map is, so the map and time scrubber
/// work before the server exists. Deterministic: the same place and hour give the same values.
enum MockEnvironment {
    static func series(for query: EnvQuery) -> EnvSeries {
        let step = TimeInterval(max(query.stepMinutes, 5) * 60)
        let start = (query.from.timeIntervalSince1970 / step).rounded(.down) * step
        let times = stride(from: start, through: query.to.timeIntervalSince1970, by: step).map(Date.init(timeIntervalSince1970:))

        // Stations sit on a grid that snaps to powers of two (about 5 per side), so panning
        // doesn't reshuffle them and each zoom level shows a sensible number.
        let span = max(query.bbox.maxLat - query.bbox.minLat, 0.001)
        let cell = 0.01 * pow(2, (log2(span / 5 / 0.01)).rounded())
        var stations: [EnvSeries.Station] = []
        var lat = (query.bbox.minLat / cell).rounded(.up) * cell
        while lat < query.bbox.maxLat {
            var lon = (query.bbox.minLon / cell).rounded(.up) * cell
            while lon < query.bbox.maxLon {
                let seed = hash(lat, lon)
                // Jitter inside the cell; roughly 2 in 3 cells have an air sensor, 1 in 3 water.
                let jLat = lat + (unit(seed, 1) - 0.5) * cell * 0.8
                let jLon = lon + (unit(seed, 2) - 0.5) * cell * 0.8
                if query.kinds.contains(.air), unit(seed, 3) < 0.66 {
                    stations.append(air(id: "mock-air-\(seed % 100_000)", lat: jLat, lon: jLon, seed: seed, times: times))
                }
                if query.kinds.contains(.water), unit(seed, 4) < 0.33 {
                    stations.append(water(id: "mock-water-\(seed % 100_000)", lat: jLat + cell * 0.2, lon: jLon - cell * 0.2,
                                          seed: seed, times: times))
                }
                lon += cell
            }
            lat += cell
        }
        return EnvSeries(schema: EnvSeries.schema, from: query.from, to: query.to, stepMinutes: query.stepMinutes,
                         stations: stations, error: nil)
    }

    private static func air(id: String, lat: Double, lon: Double, seed: UInt64, times: [Date]) -> EnvSeries.Station {
        let base = 4 + unit(seed, 5) * 22 // µg/m³: some neighborhoods are dirtier
        let readings = times.map { time -> EnvSeries.Reading in
            let hour = Calendar.current.component(.hour, from: time)
            // Rush-hour peaks plus a slow multi-day swing and noise.
            let rush = exp(-pow(Double(hour) - 8, 2) / 6) + 0.8 * exp(-pow(Double(hour) - 18, 2) / 8)
            let swing = sin(time.timeIntervalSince1970 / 86_400 / 2.3 + unit(seed, 6) * 6) * 0.35 + 1
            let noise = unit(seed &+ UInt64(time.timeIntervalSince1970 / 3600), 7) * 3
            let pm25 = max(1, base * swing * (0.7 + rush * 0.8) + noise)
            let afternoon = exp(-pow(Double(hour) - 15, 2) / 10)
            let o3 = 18 + afternoon * 45 * swing + noise
            let no2 = 6 + rush * 30 * swing + noise
            return .init(t: time, values: [
                EnvMetric.pm25.rawValue: pm25.rounded(toPlaces: 1),
                EnvMetric.pm10.rawValue: (pm25 * 1.7).rounded(toPlaces: 1),
                EnvMetric.o3.rawValue: o3.rounded(),
                EnvMetric.no2.rawValue: no2.rounded(),
                EnvMetric.aqi.rawValue: aqi(pm25: pm25).rounded(),
            ])
        }
        let names = ["Park monitor", "School rooftop", "Transit hub", "Library", "Fire station", "Community garden"]
        return .init(id: id, kind: .air, name: names[Int(seed % UInt64(names.count))], lat: lat, lon: lon,
                     source: "Mock (OpenAQ-style)", readings: readings)
    }

    private static func water(id: String, lat: Double, lon: Double, seed: UInt64, times: [Date]) -> EnvSeries.Station {
        let polluted = unit(seed, 8)
        let readings = times.map { time -> EnvSeries.Reading in
            let hour = Double(Calendar.current.component(.hour, from: time))
            let daily = sin((hour - 9) / 24 * 2 * .pi)
            let rain = max(0, sin(time.timeIntervalSince1970 / 86_400 / 1.7 + unit(seed, 9) * 6)) // storm runoff
            let temperature = 14 + polluted * 6 + daily * 2
            let oxygen = 9.5 - polluted * 3.5 - daily * 0.8 - rain
            let turbidity = 0.6 + polluted * 6 + rain * 18 * (0.5 + polluted)
            let ph = 7.4 - polluted * 0.7 + daily * 0.15
            var wqi = 96 - polluted * 30 - rain * 25 * (0.4 + polluted)
            wqi = min(100, max(5, wqi))
            return .init(t: time, values: [
                EnvMetric.wqi.rawValue: wqi.rounded(),
                EnvMetric.ph.rawValue: ph.rounded(toPlaces: 2),
                EnvMetric.turbidity.rawValue: turbidity.rounded(toPlaces: 1),
                EnvMetric.dissolvedOxygen.rawValue: oxygen.rounded(toPlaces: 1),
                EnvMetric.temperature.rawValue: temperature.rounded(toPlaces: 1),
            ])
        }
        let names = ["Creek gauge", "Reservoir intake", "River station", "Harbor buoy", "Pond sensor"]
        return .init(id: id, kind: .water, name: names[Int(seed % UInt64(names.count))], lat: lat, lon: lon,
                     source: "Mock (USGS-style)", readings: readings)
    }

    /// US EPA AQI from PM2.5 (2024 breakpoints).
    static func aqi(pm25: Double) -> Double {
        let table: [(Double, Double, Double, Double)] = [
            (0, 9, 0, 50), (9.1, 35.4, 51, 100), (35.5, 55.4, 101, 150),
            (55.5, 125.4, 151, 200), (125.5, 225.4, 201, 300), (225.5, 500, 301, 500),
        ]
        let c = (pm25 * 10).rounded(.down) / 10
        for (cLow, cHigh, iLow, iHigh) in table where c <= cHigh {
            return (iHigh - iLow) / (cHigh - cLow) * (max(c, cLow) - cLow) + iLow
        }
        return 500
    }

    private static func hash(_ lat: Double, _ lon: Double) -> UInt64 {
        var h = UInt64(bitPattern: Int64((lat * 1000).rounded())) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64((lon * 1000).rounded())) &* 0xC2B2_AE3D_27D4_EB4F
        return h ^ (h >> 31)
    }

    /// A stable pseudo-random number in 0..<1 from a seed and a salt.
    private static func unit(_ seed: UInt64, _ salt: UInt64) -> Double {
        var x = seed &+ salt &* 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x % 1_000_000) / 1_000_000
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
