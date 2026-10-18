import SwiftUI

/// Every exposure the envlab server returned, exactly as received: fix time and accuracy, then each
/// nearby sensor with its reading time, distance, visibility, provenance and per-metric quality.
/// `no_match` shows as a data gap, never as zeros or a "safe" badge. Absent fields read "unknown".
struct ExposureLogView: View {
    @Environment(ExposureStore.self) private var store

    var body: some View {
        List {
            if store.exposures.isEmpty {
                ContentUnavailableView("No exposures yet", systemImage: "sensor",
                                       description: Text("They appear here as the server matches your location fixes."))
            }
            ForEach(store.exposures.suffix(200).reversed()) { exposure in
                Section {
                    if exposure.isMatched {
                        ForEach(exposure.sensors, id: \.deviceId) { sensor in SensorRow(sensor: sensor) }
                    } else {
                        Label(exposure.status == "no_match" ? "No sensor nearby. Data gap, not a reading."
                                                            : "Status: \(exposure.status)",
                              systemImage: "circle.dashed")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fix \(exposure.measuredAt.formatted(date: .abbreviated, time: .standard))")
                        Text(fixDetails(exposure)).font(.caption2).textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("Exposures")
    }

    private func fixDetails(_ exposure: Exposure) -> String {
        var parts = [String(format: "%.5f, %.5f", exposure.position.latitude, exposure.position.longitude)]
        parts.append(exposure.position.accuracyM.map { "±\(Int($0.rounded())) m" } ?? "accuracy unknown")
        if let radius = exposure.matchRadiusM { parts.append("match radius \(Int(radius)) m") }
        return parts.joined(separator: " · ")
    }
}

private struct SensorRow: View {
    let sensor: Exposure.Sensor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sensor.locationId.map(ExposureStore.displayName) ?? sensor.deviceId).font(.subheadline.weight(.semibold))
                Spacer()
                Tag(sensor.isSimulated ? "Simulated" : sensor.source == "sensor" ? "Sensor" : (sensor.source ?? "Source unknown"),
                    color: sensor.isSimulated ? .orange : Brand.aqua)
                Tag(sensor.visibility.map { $0 == "private" ? "Private" : $0 == "public" ? "Public" : $0 } ?? "Visibility unknown",
                    color: .gray)
            }
            Text(details).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(sensor.measurements.enumerated()), id: \.offset) { _, measurement in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(measurement.medium.capitalized) · \(measurement.metric)").font(.caption)
                    Spacer()
                    if measurement.quality == "invalid" {
                        Text("invalid, not shown").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(value(measurement)).font(.caption.monospacedDigit())
                        Text(measurement.quality ?? "quality unknown")
                            .font(.caption2).foregroundStyle(measurement.quality == "ok" ? Color.secondary : .orange)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts = [sensor.deviceId]
        parts.append(sensor.distanceM.map { "\(Int($0.rounded())) m away" } ?? "distance unknown")
        if let observed = sensor.observedAt ?? sensor.measuredAt {
            parts.append("read \(observed.formatted(date: .omitted, time: .standard))")
        } else {
            parts.append("reading time unknown")
        }
        if sensor.measuredAt == nil, sensor.receivedAt != nil { parts.append("sensor clock unsynced") }
        return parts.joined(separator: " · ")
    }

    private func value(_ measurement: Exposure.Measurement) -> String {
        var text = measurement.value.formatted(.number.precision(.fractionLength(0...2)))
        if let unit = measurement.unit, !unit.isEmpty { text += " \(unit)" }
        if let mean = measurement.rollingMean {
            text += " (mean \(mean.formatted(.number.precision(.fractionLength(0...2))))"
            if let count = measurement.sampleCount { text += ", n=\(count)" }
            text += ")"
        }
        return text
    }
}

private struct Tag: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}
