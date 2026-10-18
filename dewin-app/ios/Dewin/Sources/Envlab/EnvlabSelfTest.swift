#if DEBUG
import CoreLocation
import Foundation

/// `--envlab-selftest --envlab-url=<url> --envlab-token=<token>`: an end-to-end check against an envlab
/// server, normally the team's local mock (`backend/scripts/mock_api.py`, http://127.0.0.1:8765, tokens
/// dev-only-alice-token / dev-only-bob-token). The token is used for this run only, never saved.
///
/// Connects, re-sends the previous run's last fix (expects `duplicate`), sends three fixes near the
/// fixture sensor at 25.7617,-80.1918 one second apart and one far away (40.7,-74.0), re-sends the
/// first (expects `duplicate`), waits for their `exposure:update`s, reads the last hour of history,
/// then logs one summary line. On the mock, near fixes match "pico-01" (and Alice's private
/// "mock-alice-home"); on the live gateway they match the simulated sim-pico-01/02 (public) and
/// sim-pico-03 (the demo identity's private one), with water temperature and air humidity only.
enum EnvlabSelfTest {
    static let lastFixKey = "envlab.selftest.lastFix"

    @MainActor static func runIfRequested(client: EnvlabClient, store: ExposureStore) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--envlab-selftest") else { return }
        func value(_ name: String) -> String? {
            args.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        let url = value("--envlab-url") ?? EnvlabSettings.defaultURL
        guard let token = value("--envlab-token"), !token.isEmpty else {
            NSLog("[Envlab] selftest: FAILED, pass --envlab-token=<token>")
            return
        }
        NSLog("[Envlab] selftest: starting against %@", url)
        client.apply(EnvlabSettings(mode: .live, url: url, token: token)) // not saved
        Task { @MainActor in await run(client: client, store: store) }
    }

    @MainActor private static func run(client: EnvlabClient, store: ExposureStore) async {
        guard await wait(seconds: 20, until: { client.isConnected }) else {
            NSLog("[Envlab] selftest: FAILED, not connected (%@)", client.state)
            return
        }
        let before = client.counters
        let defaults = UserDefaults.standard

        // The previous run's last fix, byte for byte: the server must answer duplicate.
        var expectedDuplicates = 1
        if let data = defaults.data(forKey: lastFixKey),
           let previous = try? EnvlabCoding.decoder.decode(EnvlabLocationUpdate.self, from: data),
           client.enqueue(previous) {
            expectedDuplicates += 1
            NSLog("[Envlab] selftest: re-sent the previous run's fix %@", String(previous.eventId.prefix(8)))
        }

        let near = [(25.7617, -80.1918), (25.76172, -80.19183), (25.76168, -80.19176)]
        var fixes: [EnvlabLocationUpdate] = []
        for (index, point) in (near + [(40.7, -74.0)]).enumerated() {
            if index > 0 { try? await Task.sleep(for: .seconds(1)) }
            let location = CLLocation(coordinate: .init(latitude: point.0, longitude: point.1), altitude: 0,
                                      horizontalAccuracy: 8, verticalAccuracy: -1, timestamp: .now)
            let fix = EnvlabLocationUpdate(location: location)
            fixes.append(fix)
            client.enqueue(fix)
        }
        let ids = Set(fixes.map(\.eventId))
        _ = await wait(seconds: 30) { client.pendingCount == 0 }
        // A retry of an acked fix: same event ID and payload.
        client.enqueue(fixes[0])
        _ = await wait(seconds: 15) { client.pendingCount == 0 }
        let arrived = await wait(seconds: 15) {
            ids.isSubset(of: Set(store.exposures.lazy.map(\.locationEventId)))
        }

        let mine = store.exposures.filter { ids.contains($0.locationEventId) }
        let matched = mine.filter(\.isMatched)
        let noMatch = mine.filter { !$0.isMatched }
        let farID = fixes[3].eventId
        let now = Date()
        let history = await client.syncHistory(from: now.addingTimeInterval(-3_600), to: now)
        let series = store.series(from: now.addingTimeInterval(-3_600), to: now)
        if let data = try? EnvlabCoding.encoder.encode(fixes[1]) { defaults.set(data, forKey: lastFixKey) }

        let after = client.counters
        let acks = after.acks - before.acks
        let duplicates = after.duplicates - before.duplicates
        NSLog("[Envlab] selftest: acks=%@, duplicates=%@, exposures matched=%@ no_match=%@, history items=%@, series stations=%@",
              String(acks), String(duplicates), String(matched.count), String(noMatch.count),
              String(history.items), String(series.stations.count))
        for station in series.stations {
            let latest = station.readings.last.map { reading in
                reading.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            } ?? ""
            NSLog("[Envlab] selftest: station %@ (%@, %@) %@ readings, latest %@",
                  station.id, station.name ?? "", station.source ?? "", String(station.readings.count), latest)
        }
        for exposure in mine {
            let sensors = exposure.sensors.map { "\($0.deviceId)/\($0.visibility ?? "?")@\($0.distanceM.map { String(format: "%.1f m", $0) } ?? "?")" }
            NSLog("[Envlab] selftest: fix %@ → %@%@ %@", String(exposure.locationEventId.prefix(8)), exposure.status,
                  exposure.isSimulated ? " (simulated)" : "", sensors.joined(separator: ", "))
        }

        var problems: [String] = []
        if acks < fixes.count + 1 { problems.append("expected \(fixes.count + 1)+ acks") }
        if duplicates < expectedDuplicates { problems.append("expected \(expectedDuplicates) duplicates") }
        if !arrived { problems.append("not every exposure:update arrived") }
        if matched.count < near.count { problems.append("near fixes should match") }
        if !noMatch.contains(where: { $0.locationEventId == farID }) { problems.append("far fix should be no_match") }
        if !history.complete || history.items < fixes.count { problems.append("history incomplete") }
        if series.stations.isEmpty { problems.append("no series stations") }
        NSLog("[Envlab] selftest: %@ (state %@, %@ waiting, last error %@)",
              problems.isEmpty ? "PASS" : "FAIL: " + problems.joined(separator: "; "),
              client.state, String(client.pendingCount), client.lastError ?? "none")
    }

    @MainActor private static func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }
}
#endif
