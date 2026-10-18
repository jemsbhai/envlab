import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Home: a calm dashboard of today. Greeting, the 90-day "How you dewin?" score, food / air / water
/// at a glance, photos to review, quick logging, two tips and the connection status.
struct HomeView: View {
    @Environment(GlassesController.self) private var glasses
    @Environment(MealPipeline.self) private var pipeline
    @Environment(WakeWordListener.self) private var wakeWord
    @Environment(LocationReporter.self) private var location
    @Environment(NearbyHealthStore.self) private var nearby
    @Environment(ReportStore.self) private var report
    @Environment(Router.self) private var router
    @Query(sort: \Meal.capturedAt, order: .reverse) private var meals: [Meal]

    var body: some View {
        let goals = Goals.current
        let today = Insights.day(.now, from: meals)
        let toReview = meals.filter { $0.status == .review }
        let aqi = nearby.homeValue(.aqi).value

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HomeGreeting()

                    HowYouDewinSummaryCard(report: report.report, isLoading: report.isLoading) {
                        router.showReport = true
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HomeSectionHeader(title: "Today")
                        HomeGlanceGrid(today: today, goals: goals)
                    }

                    if !toReview.isEmpty {
                        HomeReviewCard(meals: toReview)
                    }

                    HomeQuickActions()

                    tipsCard(today: today, goals: goals, aqi: aqi)

                    statusRow
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .tint(.homeAccent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Image("Wordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 22)
                        .accessibilityLabel("Dewin")
                }
            }
            .navigationDestination(for: Meal.self) { MealDetailView(meal: $0) }
            .refreshable {
                if let coordinate = location.lastLocation?.coordinate { nearby.refresh(around: coordinate, force: true) }
                await report.load(force: true)
            }
            .task { await report.load() }
        }
    }

    // MARK: For you today

    /// At most two tips: one about food, one about the air right now.
    @ViewBuilder
    private func tipsCard(today: DaySummary, goals: Goals, aqi: Double?) -> some View {
        let tips = [Insights.tips(for: today, goals: goals).first, aqi.map { HealthAdvice.air(aqi: $0) }].compactMap { $0 }
        if !tips.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HomeSectionHeader(title: "For you today")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tips.enumerated()), id: \.element.id) { index, tip in
                        if index > 0 { Divider() }
                        TipRow(tip: tip)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .homeCard()
            }
        }
    }

    // MARK: Status

    private var statusRow: some View {
        let chips = Group {
            StatusChip(systemImage: "eyeglasses", text: glasses.isReady ? "Glasses" : "Glasses off", ok: glasses.isReady)
            StatusChip(systemImage: "waveform", text: wakeWord.isListening ? "Hey Dewin" : "Wake word off",
                       ok: wakeWord.isListening)
            StatusChip(systemImage: "antenna.radiowaves.left.and.right",
                       text: pipeline.backendConnected ? "Server" : "Offline", ok: pipeline.backendConnected)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(spacing: 6) { chips }
        }
    }
}

// MARK: - Greeting

/// "Welcome back, Sam" and today's date. Without a name, a small inline field to set one.
private struct HomeGreeting: View {
    @AppStorage(UserProfile.firstNameKey) private var storedName = ""
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var firstName: String { storedName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.4)
            Text(firstName.isEmpty ? "Welcome back" : "Welcome back, \(firstName)")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)

            if firstName.isEmpty { namePrompt.padding(.top, 8) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var namePrompt: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("What should we call you?", text: $draft)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($nameFocused)
                .onSubmit(save)
            if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Save", action: save)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
    }

    private func save() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        storedName = name
        draft = ""
        nameFocused = false
    }
}

// MARK: - How you dewin?

/// The one dark brand moment on the page: the 90-day score on navy, like the app icon.
private struct HomeGlanceGrid: View {
    @Environment(LocationReporter.self) private var location
    @Environment(NearbyHealthStore.self) private var nearby
    @Environment(Router.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    let today: DaySummary
    let goals: Goals
    /// Authorized but still no fix after a while (no GPS, Location Services trouble): stop showing a spinner.
    @State private var locationTimedOut = false

    var body: some View {
        grid
            .task(id: location.isAuthorized && location.lastLocation == nil) {
                locationTimedOut = false
                guard location.isAuthorized, location.lastLocation == nil else { return }
                try? await Task.sleep(for: .seconds(15))
                if !Task.isCancelled, location.lastLocation == nil { locationTimedOut = true }
            }
    }

    @ViewBuilder
    private var grid: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 12) {
                foodTile
                mealsTile
                if location.isAuthorized {
                    envTile(.air)
                    envTile(.water)
                } else {
                    locationTile
                }
            }
        } else {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    foodTile
                    mealsTile
                }
                GridRow {
                    if location.isAuthorized {
                        envTile(.air)
                        envTile(.water)
                    } else {
                        locationTile.gridCellColumns(2)
                    }
                }
            }
        }
    }

    // MARK: Food

    private var foodTile: some View {
        let eaten = today.totals.calories ?? 0
        let remaining = goals.calories - eaten
        return HomeTile(title: "Food", systemImage: "fork.knife", tint: .green) {
            router.open(Router.FoodSection.today)
        } content: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(remaining >= 0 ? Int(remaining).formatted() : "+\(Int(-remaining).formatted())")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(remaining >= 0 ? Color.primary : Color.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(remaining >= 0 ? "cal left" : "cal over")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HomeMiniRing(progress: goals.calories > 0 ? eaten / goals.calories : 0)
                    .frame(width: 44, height: 44)
            }
        } footer: {
            HStack(spacing: 6) {
                HealthScoreBadge(score: today.healthScore)
                Text(today.healthScore == nil ? "No score yet" : "health score")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(foodLabel(eaten: eaten, remaining: remaining))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Food, Today")
    }

    private func foodLabel(eaten: Double, remaining: Double) -> String {
        var text = remaining >= 0 ? "Food: \(Int(remaining)) calories left" : "Food: \(Int(-remaining)) calories over your goal"
        text += ", \(Int(eaten)) of \(Int(goals.calories)) eaten"
        if let score = today.healthScore { text += ", health score \(Int(score.rounded()))" }
        return text
    }

    // MARK: Meals

    private var mealsTile: some View {
        let last = today.analyzed.max { $0.capturedAt < $1.capturedAt }
        return HomeTile(title: "Meals", systemImage: "list.bullet", tint: Brand.teal) {
            router.open(Router.FoodSection.log)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(today.mealCount)")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Text(today.mealCount == 1 ? "meal today" : "meals today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if let last {
                Text("Last: \(last.name ?? "Meal")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Nothing logged yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Meals: \(today.mealCount) today" + (last.map { ", last was \($0.name ?? "a meal")" } ?? ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Food, Log")
    }

    // MARK: Air & water

    private func envTile(_ kind: EnvKind) -> some View {
        // AQI / water quality index when measured; live sensors may only report raw values (PM2.5, pH…).
        let metric: EnvMetric = nearby.headlineMetric(kind) ?? (kind == .air ? .aqi : .wqi)
        let now = nearby.homeValue(metric)
        let state = envState(value: now.value)
        return HomeTile(title: kind.label, systemImage: kind.symbol, tint: kind == .air ? Brand.blue : Brand.teal) {
            router.open(Router.HealthSection.today)
        } content: {
            switch state {
            case let .value(value):
                let level = metric.level(value)
                // Temperature and humidity are context, not a verdict: neutral color, no level word.
                let judged = metric.isAssessment
                // Past the default text size the label goes under the dot, so it wraps on whole words.
                let layout = typeSize > .large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                               : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    HomeLevelDot(text: Self.dotText(metric, value), color: judged ? level.color : Brand.gray)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(judged ? Self.shortLabel(level) : metric.format(value))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.caption(metric))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityHidden(true)
            case .checking:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            case .noFix:
                placeholder("Can't find you", systemImage: "location.slash")
            case .failed:
                placeholder("Couldn't load", systemImage: "exclamationmark.triangle")
            case .noSensor:
                placeholder("No sensor nearby", systemImage: "sensor")
            }
        } footer: {
            Text(envFooter(state: state, station: now.station))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(envLabel(kind, metric: metric, state: state, station: now.station))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Health, Today")
    }

    private enum EnvState {
        case value(Double), checking, noFix, failed, noSensor
    }

    private func envState(value: Double?) -> EnvState {
        if let value { return .value(value) }
        if location.lastLocation == nil { return locationTimedOut ? .noFix : .checking }
        if nearby.isLoading { return .checking }
        return nearby.error != nil ? .failed : .noSensor
    }

    /// The station line under a reading, with its age once it's over an hour old.
    private func envFooter(state: EnvState, station: HomeStationReading?) -> String {
        switch state {
        case .value:
            guard let station else { return "Your area" }
            var text = "\(station.station.name ?? "Nearby sensor") · \(distance(station.distanceKm))"
            if station.station.source == "Simulated" { text += " · simulated" }
            if Date.now.timeIntervalSince(station.reading.t) > 3600 {
                text += " · \(station.reading.t.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))"
            }
            return text
        case .checking: return " "
        case .noFix: return "Check Location Services"
        case .failed: return "Pull down to retry"
        case .noSensor: return "None within \(distance(NearbyHealthStore.maxDistanceKm))"
        }
    }

    /// The number inside the dot: indexes as is, raw values without their unit (the caption names them).
    private static func dotText(_ metric: EnvMetric, _ value: Double) -> String {
        if metric == .aqi || metric == .wqi { return metric.format(value) }
        return value < 10 ? value.formatted(.number.precision(.fractionLength(0...1))) : "\(Int(value.rounded()))"
    }

    private static func caption(_ metric: EnvMetric) -> String {
        switch metric {
        case .aqi: "air quality"
        case .wqi: "water quality"
        default: metric.isAssessment ? "\(metric.label) \(metric.unit)".trimmingCharacters(in: .whitespaces)
                                     : metric.plainName.lowercased()
        }
    }

    /// The tile is half the screen wide, so the longest EPA name gets a shorter one here.
    /// VoiceOver still reads the full name.
    private static func shortLabel(_ level: EnvLevel) -> String {
        level == .sensitive ? "Unhealthy for some" : level.label
    }

    private func placeholder(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
    }

    private func envLabel(_ kind: EnvKind, metric: EnvMetric, state: EnvState, station: HomeStationReading?) -> String {
        switch state {
        case let .value(value):
            let what = metric == .aqi ? "air quality index" : metric == .wqi ? "water quality" : metric.plainName.lowercased()
            var text = metric.isAssessment
                ? "\(kind.label): \(metric.level(value).label), \(what) \(metric.format(value))"
                : "\(kind.label): \(what) \(metric.format(value))"
            if let station {
                text += ", nearest sensor \(station.station.name ?? "nearby"), \(distance(station.distanceKm)) away"
            }
            return text
        case .checking: return "\(kind.label): checking"
        case .noFix: return "\(kind.label): can't find your location"
        case .failed: return "\(kind.label): couldn't load. Pull down to retry"
        case .noSensor: return "\(kind.label): no sensor nearby"
        }
    }

    private func distance(_ km: Double) -> String {
        Measurement(value: km, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    /// Location off: one wide tile in place of Air and Water.
    private var locationTile: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HomeTileIcon(systemImage: "location.fill", tint: Brand.blue)
                Text("Air & water near you")
                    .font(.subheadline.weight(.semibold))
            }
            Text("Turn on location to see the air and water quality where you are.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if location.authorization == .notDetermined {
                    location.requestPermission()
                } else if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text(location.authorization == .notDetermined ? "Turn on location" : "Open Settings")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .homeCard()
    }
}

/// A tappable card: icon + title + chevron, the main figure, and a one-line footer.
private struct HomeTile<Content: View, Footer: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    HomeTileIcon(systemImage: systemImage, tint: tint)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                content
                Spacer(minLength: 0)
                footer
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .homeCard()
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(HomePressStyle())
    }
}

private struct HomeTileIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The value inside a ring in its level's color. The level's name always sits next to it.
private struct HomeLevelDot: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(.headline, design: .rounded).weight(.bold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(6)
            .frame(width: 50, height: 50)
            .background(color.opacity(0.16), in: Circle())
            .overlay(Circle().strokeBorder(color, lineWidth: 3))
    }
}

/// A small calorie ring without labels; the tile carries the numbers.
private struct HomeMiniRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(progress > 1.1 ? Color.orange : Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: progress)
        }
        .padding(3)
        .accessibilityHidden(true)
    }
}

// MARK: - To review

/// Glasses photos waiting to be sent. Tap to review them in Food › Today, or send them all from here.
private struct HomeReviewCard: View {
    @Environment(MealPipeline.self) private var pipeline
    @Environment(Router.self) private var router
    let meals: [Meal]
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "To review", count: meals.count)
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    router.open(Router.FoodSection.today)
                } label: {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(meals) { MealThumbnail(photo: $0.photo, size: 64) }
                        }
                    }
                    .scrollDisabled(meals.count < 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(meals.count) \(meals.count == 1 ? "photo" : "photos") to review")
                .accessibilityHint("Opens Food, Today")

                HStack(spacing: 12) {
                    Text("Send them to get calories and nutrients.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        sending = true
                        Task {
                            for meal in meals { await pipeline.send(meal) }
                            sending = false
                        }
                    } label: {
                        if sending {
                            ProgressView()
                        } else {
                            Label(meals.count == 1 ? "Send" : "Send all", systemImage: "paperplane.fill")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(sending)
                }
            }
            .padding(16)
            .homeCard()
        }
    }
}

// MARK: - Quick actions

/// Log a meal: through the glasses (or get them connected), or from the photo library.
private struct HomeQuickActions: View {
    @Environment(GlassesController.self) private var glasses
    @Environment(MealPipeline.self) private var pipeline
    @Environment(WakeWordListener.self) private var wakeWord
    @Environment(Router.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @State private var pickerItem: PhotosPickerItem?
    @State private var pickerFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "Log a meal")
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { buttons }
                    VStack(spacing: 10) { buttons }
                }
                if pipeline.busy {
                    Text(pipeline.lastStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if pickerFailed {
                    Label("Couldn't open that photo. Try another one.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if wakeWord.isListening {
                    Label {
                        Text("Try \u{201C}Hey Dewin, how many calories did I eat today?\u{201D}")
                    } icon: {
                        Image(systemName: "waveform").foregroundStyle(.tint)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .homeCard()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            // Reset right away so picking the same photo again still fires.
            pickerItem = nil
            Task { await logPicked(item) }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: primaryAction) {
            HStack(spacing: 8) {
                if pipeline.busy {
                    ProgressView().tint(primaryForeground)
                } else {
                    Image(systemName: glasses.isReady ? "camera.fill" : "eyeglasses")
                }
                Text(primaryTitle).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(primaryForeground)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(HomePressStyle())
        .disabled(pipeline.busy)

        PhotosPicker(selection: $pickerItem, matching: .images) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle")
                Text("From photos").lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.homeAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(HomePressStyle())
        .disabled(pipeline.busy)
        .accessibilityLabel("Log from photo library")
    }

    /// White on teal in light mode; navy on aqua in dark mode, where the accent is light.
    private var primaryForeground: Color { colorScheme == .dark ? Brand.navy : .white }

    private var primaryTitle: String {
        if !glasses.isRegistered { return "Set up glasses" }
        if !glasses.isReady { return "Connect glasses" }
        return "Snap with glasses"
    }

    private func primaryAction() {
        if !glasses.isRegistered {
            router.tab = .settings
        } else if !glasses.isReady {
            glasses.connect()
        } else {
            Task { await pipeline.logMealFromGlasses(trigger: "app_button") }
        }
    }

    private func logPicked(_ item: PhotosPickerItem) async {
        pickerFailed = false
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadUnknown) }
            await pipeline.logMeal(photo: data)
        } catch {
            NSLog("[Home] photo load failed: %@", String(describing: error))
            pickerFailed = true
        }
    }
}

// MARK: - Shared bits

private struct HomeSectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.bold))
            if let count {
                Text("\(count)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Dims slightly while pressed, so cards feel tappable without a highlight color.
private struct HomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private extension View {
    /// Home's card surface: grouped background, continuous 20 pt corners.
    func homeCard() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private extension Color {
    /// The brand accent: teal in light mode, aqua in dark (same as the AccentColor asset), set explicitly
    /// so Home's buttons stay on brand.
    static let homeAccent = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Brand.aqua) : UIColor(Brand.teal) })
}

// MARK: - Air & water values

/// A station and its latest reading, as `NearbyHealthStore.nearest` returns it.
private typealias HomeStationReading = (station: EnvSeries.Station, reading: EnvSeries.Reading, distanceKm: Double)

private extension NearbyHealthStore {
    /// The value Home shows for `metric`, from the same source as Health › Today: the blended area value
    /// for air (falling back to the nearest station), the nearest station for water. `station` is the
    /// nearest one that actually reports `metric`.
    func homeValue(_ metric: EnvMetric, now: Date = .now) -> (value: Double?, station: HomeStationReading?) {
        let station = stations(metric.kind).lazy.compactMap { entry -> HomeStationReading? in
            guard let reading = entry.station.reading(at: now), reading.values[metric.rawValue] != nil else { return nil }
            return (entry.station, reading, entry.distanceKm)
        }.first
        let stationValue = station?.reading.values[metric.rawValue]
        let value = metric.kind == .air ? (areaValue(metric, at: now) ?? stationValue) : stationValue
        return (value, station)
    }
}
