import Charts
import MapKit
import SwiftUI

/// Health › Map: air & water quality on a map, with a time scrubber to replay the last day or week.
struct EnvironmentView: View {
    @Environment(EnvironmentStore.self) private var store
    @Environment(LocationReporter.self) private var location
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: SelectedStation?
    @State private var centered = false

    var body: some View {
        @Bindable var store = store
        Map(position: $position) {
            UserAnnotation()
            ForEach(store.stations) { station in
                Annotation(station.name ?? station.kind.label, coordinate: station.coordinate, anchor: .center) {
                    Button { selected = SelectedStation(id: station.id, snapshot: station) } label: {
                        StationPin(station: station, pin: store.pin(for: station))
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            store.regionChanged(context.region)
        }
        .safeAreaInset(edge: .top) { controls }
        .safeAreaInset(edge: .bottom) { TimeScrubber() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.isLoading { ProgressView() } else {
                    Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload readings")
                }
            }
        }
        .sheet(item: $selected) { selection in
            StationDetail(stationID: selection.id, snapshot: selection.snapshot)
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            if !location.isAuthorized, location.authorization == .notDetermined { location.requestPermission() }
            centerOnUser()
            if store.stations.isEmpty { store.reload() }
        }
        .onChange(of: location.lastLocation == nil) { centerOnUser() }
    }

    /// Opens at neighborhood scale (~20 km across): sensors are kilometers apart.
    private func centerOnUser() {
        guard !centered, let coordinate = location.lastLocation?.coordinate else { return }
        centered = true
        position = .region(MKCoordinateRegion(center: coordinate, span: .init(latitudeDelta: 0.18, longitudeDelta: 0.18)))
    }

    private var controls: some View {
        @Bindable var store = store
        return VStack(spacing: 8) {
            Picker("Kind", selection: $store.kind) {
                ForEach(EnvKind.allCases) { kind in Label(kind.label, systemImage: kind.symbol).tag(kind) }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(EnvMetric.metrics(for: store.kind)) { metric in
                        Button(metric.label) { store.metric = metric }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(store.metric == metric ? Color.accentColor : Color(.secondarySystemBackground),
                                        in: Capsule())
                            .foregroundStyle(store.metric == metric ? Color.white : Color.primary)
                    }
                }
            }

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !location.isAuthorized {
                Button {
                    location.requestPermission()
                } label: {
                    Label("Use my location to collect readings nearby", systemImage: "location")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}

/// The station a tap opened. The sheet reads the live station by id, so it updates as readings arrive.
private struct SelectedStation: Identifiable {
    let id: String
    let snapshot: EnvSeries.Station
}

/// A colored dot with the latest value inside. Level colors only for health metrics; temperature and
/// humidity are slate. A metric other than the selected one is named under the dot.
private struct StationPin: View {
    let station: EnvSeries.Station
    let pin: StationPinValue?

    var body: some View {
        let level = pin?.level
        ZStack {
            Circle()
                .fill(pin == nil ? Color.gray.opacity(0.6) : level?.color ?? Brand.gray)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
            if station.kind == .water {
                Image(systemName: "drop.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.85))
                    .offset(y: -13)
            }
            Text(pin.map(Self.short) ?? "–")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(level == .moderate ? Color.black : Color.white)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
        }
        .frame(width: 36, height: 36)
        .opacity(pin?.isStale == true ? 0.55 : 1)
        .overlay(alignment: .bottom) {
            if let pin, pin.isFallback {
                Text(pin.metric.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Brand.navy.opacity(0.8), in: Capsule())
                    .fixedSize()
                    .offset(y: 15)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: pin)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Shows this station's latest readings")
    }

    private var accessibilityText: String {
        let name = station.name ?? station.kind.label
        guard let pin else { return "\(name): no recent reading" }
        let level = pin.level.map { ", \($0.label)" } ?? ""
        return "\(name): \(pin.metric.plainName) \(pin.metric.format(pin.value))\(level), \(updatedAgo(pin.time))"
    }

    static func short(_ pin: StationPinValue) -> String {
        let value = pin.value
        switch pin.metric {
        case .temperature, .airTemperature: return "\(Int(value.rounded()))°"
        case .humidity: return "\(Int(value.rounded()))%"
        case .ph: return value.formatted(.number.precision(.fractionLength(1)))
        case .aqi, .wqi: return "\(Int(value.rounded()))"
        default: return value < 10 ? value.formatted(.number.precision(.fractionLength(0...1))) : "\(Int(value.rounded()))"
        }
    }
}

/// "just now", "2 min. ago". Sensor clocks can run a little ahead of the phone's: that's "just now" too.
private func updatedAgo(_ date: Date, now: Date = .now) -> String {
    now.timeIntervalSince(date) < 60 ? "updated just now"
        : "updated " + date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
}

/// Play button, slider over the time buckets, and a strip showing the worst level per bucket.
private struct TimeScrubber: View {
    @Environment(EnvironmentStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(store.isAtLatest ? "Now" : store.currentTime.map(timeLabel) ?? "No data")
                            .font(.headline.monospacedDigit())
                        if store.isAtLatest, let newest = store.newestReading {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(updatedAgo(newest, now: context.date))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let worst = store.worst {
                        let place = worst.station.name ?? "a station"
                        Text(store.metric.isAssessment
                             ? "\(store.metric.level(worst.value).label) · worst \(store.metric.label) \(store.metric.format(worst.value)) at \(place)"
                             : "\(store.metric.plainName) up to \(store.metric.format(worst.value)) at \(place)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("\(store.stations.count) stations in view").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Picker("Range", selection: $store.range) {
                        ForEach(EnvironmentStore.Range.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label(store.range.label, systemImage: "clock.arrow.circlepath").font(.caption.weight(.semibold))
                }
            }

            LevelStrip()
                .frame(height: 8)
                .clipShape(Capsule())

            HStack(spacing: 12) {
                Button { store.togglePlay() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel(store.isPlaying ? "Pause" : "Play through time")
                .disabled(store.frames.count < 2)

                Slider(
                    value: Binding(
                        get: { Double(store.frameIndex) },
                        set: { store.stopPlaying(); store.frameIndex = Int($0.rounded()) }
                    ),
                    in: 0...Double(max(store.frames.count - 1, 1)),
                    step: 1
                )
                .disabled(store.frames.count < 2)

                Button("Now") { store.stopPlaying(); store.frameIndex = max(store.frames.count - 1, 0) }
                    .font(.caption.weight(.semibold))
                    .disabled(store.frameIndex >= store.frames.count - 1)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal).padding(.bottom, 6)
    }

    private func timeLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// Worst level across visible stations for every time bucket: the shape of the day at a glance.
private struct LevelStrip: View {
    @Environment(EnvironmentStore.self) private var store

    var body: some View {
        let metric = store.metric
        // Worst level per frame; context metrics (temperature, humidity) only show whether there was data.
        let levels: [Color?] = store.frames.indices.map { index in
            let values = store.stations.compactMap { store.reading(for: $0, frame: index)?.values[metric.rawValue] }
            guard !values.isEmpty else { return nil }
            return metric.isAssessment ? values.map(metric.level).max()?.color : Brand.blue
        }
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(levels.indices, id: \.self) { index in
                    Rectangle()
                        .fill(levels[index] ?? Color.gray.opacity(0.3))
                        .opacity(index == store.frameIndex ? 1 : 0.55)
                }
            }
            .overlay(alignment: .leading) {
                if levels.count > 1 {
                    Rectangle().fill(.primary).frame(width: 2)
                        .offset(x: geometry.size.width * CGFloat(store.frameIndex) / CGFloat(levels.count - 1) - 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One station: when it last reported, every latest value, and its history for the selected metric.
private struct StationDetail: View {
    @Environment(EnvironmentStore.self) private var store
    /// The station shown; "Also here" switches it.
    @State private var stationID: String
    /// Shown if the station leaves the map area while the sheet is open.
    let snapshot: EnvSeries.Station

    init(stationID: String, snapshot: EnvSeries.Station) {
        _stationID = State(initialValue: stationID)
        self.snapshot = snapshot
    }

    /// The live station: the map reloads as new readings arrive.
    private var station: EnvSeries.Station { store.stations.first { $0.id == stationID } ?? snapshot }

    /// Sensors this close draw as one pin at city zoom: list them so each can be opened.
    private static let alsoHereMeters: CLLocationDistance = 500

    var body: some View {
        let station = station
        let latest = station.readings.last
        let metric = chartMetric(station)
        let points = metric.map { metric in
            station.readings.compactMap { reading in reading.values[metric.rawValue].map { (reading.t, $0) } }
        } ?? []
        NavigationStack {
            List {
                Section { header(station, latest: latest) }

                if let latest {
                    Section {
                        ForEach(EnvMetric.metrics(for: station.kind)) { item in
                            if let value = latest.values[item.rawValue] { row(item, value) }
                        }
                        // Metrics the app doesn't know yet, as reported.
                        ForEach(latest.values.keys.filter { EnvMetric(rawValue: $0) == nil }.sorted(), id: \.self) { key in
                            LabeledContent(key, value: (latest.values[key] ?? 0).formatted(.number.precision(.fractionLength(0...2))))
                        }
                    } header: {
                        Text("Latest · \(latest.t.formatted(date: .abbreviated, time: .shortened))")
                    }
                }

                if let metric, !points.isEmpty {
                    Section {
                        Chart {
                            ForEach(points, id: \.0) { point in
                                LineMark(x: .value("Time", point.0), y: .value(metric.label, point.1))
                                    .interpolationMethod(.monotone)
                                    .foregroundStyle(Brand.aqua.opacity(0.7))
                                PointMark(x: .value("Time", point.0), y: .value(metric.label, point.1))
                                    .symbolSize(18)
                                    .foregroundStyle(metric.isAssessment ? metric.level(point.1).color : Brand.blue)
                            }
                            if !store.isAtLatest, let time = store.currentTime {
                                RuleMark(x: .value("Selected", time))
                                    .foregroundStyle(.secondary)
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            }
                        }
                        .frame(height: 180)
                        .chartYAxisLabel(metric.unit)
                    } header: {
                        Text("\(metric.plainName) · last \(store.range.label)")
                    } footer: {
                        Text("\(points.count) reading\(points.count == 1 ? "" : "s")")
                    }
                }

                let alsoHere = alsoHere(station)
                if !alsoHere.isEmpty {
                    Section("Also here") {
                        ForEach(alsoHere) { other in
                            Button { stationID = other.id } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(other.name ?? other.kind.label).foregroundStyle(.primary)
                                        Text(Self.device(other)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let pin = store.pin(for: other) {
                                        Text(pin.metric.format(pin.value)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }

                Section {
                    LabeledContent("Source", value: station.source ?? "Unknown")
                    LabeledContent("Device", value: Self.device(station))
                    LabeledContent("Measures", value: station.kind.label)
                    LabeledContent("Location", value: String(format: "%.4f, %.4f", station.lat, station.lon))
                }
            }
            .navigationTitle(station.name ?? station.kind.label)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func header(_ station: EnvSeries.Station, latest: EnvSeries.Reading?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: station.kind.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Brand.navy)
                .frame(width: 44, height: 44)
                .background(Brand.dropGradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("\(station.kind.label) sensor").font(.headline)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(latest.map { "\(Self.device(station)) · \(updatedAgo($0.t, now: context.date).replacingOccurrences(of: "updated ", with: ""))" } ?? "No readings in this range")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            Spacer()
            let simulated = station.source == "Simulated"
            Text(simulated ? "Simulated" : station.source ?? "Sensor")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(simulated ? Brand.orange : Brand.aqua)
                .background((simulated ? Brand.orange : Brand.aqua).opacity(0.15), in: Capsule())
        }
        .padding(.vertical, 4)
    }

    private func row(_ metric: EnvMetric, _ value: Double) -> some View {
        HStack(spacing: 10) {
            if metric.isAssessment {
                Circle().fill(metric.level(value).color).frame(width: 10, height: 10)
            } else {
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5).frame(width: 10, height: 10)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(metric.plainName)
                Text(metric.isAssessment ? metric.level(value).label : "Context, not a health rating")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(metric.format(value)).font(.body.weight(.semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// Other stations of this kind within `alsoHereMeters`, nearest first.
    private func alsoHere(_ station: EnvSeries.Station) -> [EnvSeries.Station] {
        let here = CLLocation(latitude: station.lat, longitude: station.lon)
        return store.stations
            .filter { $0.id != station.id && $0.kind == station.kind }
            .map { ($0, CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: here)) }
            .filter { $0.1 <= Self.alsoHereMeters }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// "sim-pico-01" from the station id "sim-pico-01:air".
    private static func device(_ station: EnvSeries.Station) -> String {
        station.id.split(separator: ":").first.map(String.init) ?? station.id
    }

    /// The selected metric if this station measures it, else the best one it does.
    private func chartMetric(_ station: EnvSeries.Station) -> EnvMetric? {
        let measured = Set(station.readings.flatMap(\.values.keys))
        if measured.contains(store.metric.rawValue) { return store.metric }
        return EnvMetric.headlineOrder(station.kind).first { measured.contains($0.rawValue) }
            ?? EnvMetric.metrics(for: station.kind).first { measured.contains($0.rawValue) }
    }
}
