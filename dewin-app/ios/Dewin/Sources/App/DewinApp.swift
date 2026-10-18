import MWDATCore
import SwiftData
import SwiftUI

@main
struct DewinApp: App {
    private let container: ModelContainer
    @State private var glasses: GlassesController
    @State private var pipeline: MealPipeline
    @State private var wakeWord: WakeWordListener
    @State private var location: LocationReporter
    @State private var environment: EnvironmentStore
    @State private var nearby: NearbyHealthStore
    @State private var report: ReportStore
    @State private var router = Router()
    @State private var exposures: ExposureStore
    @State private var envlab: EnvlabClient
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            try Wearables.configure()
        } catch {
            NSLog("[Dewin] Wearables.configure failed: \(error)")
        }

        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        // `--mock-glasses`: pair Meta's mock Ray-Bans before anything reads SDK state.
        let useMock = args.contains("--mock-glasses")
        if useMock { MockGlassesKit.start() }
        #endif

        container = try! ModelContainer(for: Meal.self)
        let glasses = GlassesController()
        let pipeline = MealPipeline(context: container.mainContext, glasses: glasses, speaker: Speaker())
        let wakeWord = WakeWordListener(glasses: glasses)
        wakeWord.onCommand = { [weak pipeline] command in
            switch command {
            case .capture: Task { await pipeline?.logMealFromGlasses(trigger: "wake_word") }
            case let .question(text): pipeline?.answer(question: text)
            }
        }
        let location = LocationReporter { [unowned pipeline] in pipeline.currentBackend }
        pipeline.onBackendConnected = { [weak location] in location?.backendConnected() }
        _location = State(wrappedValue: location)
        // Air & water: the team's envlab gateway when it's on (Settings → Air & water data), else mock stations.
        let exposures = ExposureStore()
        let envlab = EnvlabClient(store: exposures)
        let envlabSettings = EnvlabSettings.current
        envlab.apply(envlabSettings)
        location.precise = envlabSettings.mode == .live
        location.onPreciseFix = { [weak envlab] fix in envlab?.send(fix) }
        let source = EnvironmentSource(pipeline: pipeline, exposures: exposures)
        _exposures = State(wrappedValue: exposures)
        _envlab = State(wrappedValue: envlab)
        _environment = State(wrappedValue: EnvironmentStore(query: source.query))
        _nearby = State(wrappedValue: NearbyHealthStore(query: source.query))
        let report = ReportStore(context: container.mainContext) { [unowned pipeline] in pipeline.currentBackend }
        report.onDeleted = { [weak pipeline] in pipeline?.restartBackend() }
        _report = State(wrappedValue: report)
        _glasses = State(wrappedValue: glasses)
        _pipeline = State(wrappedValue: pipeline)
        _wakeWord = State(wrappedValue: wakeWord)

        #if DEBUG
        if args.contains("--seed-week") { DemoData.seedWeek(into: container.mainContext) }
        EnvlabSelfTest.runIfRequested(client: envlab, store: exposures)
        if useMock { glasses.connect() }
        // `--mock-selftest`: once connected, press the mock capture button 3 times.
        if useMock, args.contains("--mock-selftest") {
            Task { @MainActor in
                while !glasses.isReady { try? await Task.sleep(for: .milliseconds(200)) }
                for _ in 1...3 {
                    try? await Task.sleep(for: .seconds(5))
                    MockGlassesKit.press(glasses.triggerPress)
                }
            }
        }
        // `--mock-wake-selftest`: turn on "Hey Dewin" and say it 3 times through the mock glasses.
        // Checks the recognizer comes back after each photo puts it down.
        if useMock, args.contains("--mock-wake-selftest") {
            wakeWord.enabled = true
            Task { @MainActor in
                while !wakeWord.isListening { try? await Task.sleep(for: .milliseconds(200)) }
                for _ in 1...3 {
                    try? await Task.sleep(for: .seconds(6))
                    while !wakeWord.isListening { try? await Task.sleep(for: .milliseconds(200)) }
                    MockGlassesKit.say("Hey Dewin, log this")
                }
            }
        }
        // `--mock-ask-selftest`: seed a week, then ask questions through the mock glasses.
        if useMock, args.contains("--mock-ask-selftest") {
            DemoData.seedWeek(into: container.mainContext)
            DemoData.addTomatoSandwichLunch(into: container.mainContext)
            wakeWord.enabled = true
            Task { @MainActor in
                let questions = [
                    "Hey Dewin how many calories did I eat today",
                    "Hey Dewin how much protein do I have left",
                    "Hey Dewin how many calories were in my chicken for lunch",
                    "Hey Dewin what did I have for breakfast yesterday",
                    "Hey Dewin how am I doing this week on sodium",
                    "Hey Dewin how many calories were in my tomato sandwich for lunch",
                    "Hey Dewin how much bread was in the tomato sandwich",
                    "Hey Dewin log this",
                ]
                for question in questions {
                    while !wakeWord.isListening { try? await Task.sleep(for: .milliseconds(200)) }
                    try? await Task.sleep(for: .seconds(4))
                    MockGlassesKit.say(question)
                }
                // A bare "Hey Dewin", then the question as its own utterance.
                try? await Task.sleep(for: .seconds(6))
                while !wakeWord.isListening { try? await Task.sleep(for: .milliseconds(200)) }
                MockGlassesKit.say("Hey Dewin")
                try? await Task.sleep(for: .milliseconds(900))
                MockGlassesKit.say("how much fiber have I had today")
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(glasses)
                .environment(pipeline)
                .environment(wakeWord)
                .environment(location)
                .environment(environment)
                .environment(nearby)
                .environment(report)
                .environment(router)
                .environment(exposures)
                .environment(envlab)
                .onOpenURL { url in
                    Task { await glasses.handle(url: url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { glasses.resumeIfNeeded() }
        }
        .modelContainer(container)
    }
}

/// Home · Food · Health · Settings. Keeps the nearby air & water data in step with the phone's location.
struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(LocationReporter.self) private var location
    @Environment(NearbyHealthStore.self) private var nearby
    @Environment(MealPipeline.self) private var pipeline
    @Environment(ExposureStore.self) private var exposures
    @Environment(EnvironmentStore.self) private var environment

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Router.Tab.home)
            FoodView()
                .tabItem { Label("Food", systemImage: "fork.knife") }
                .tag(Router.Tab.food)
            HealthView()
                .tabItem { Label("Health", systemImage: "aqi.medium") }
                .tag(Router.Tab.health)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Router.Tab.settings)
        }
        .fullScreenCover(isPresented: $router.showReport) {
            NavigationStack { HowYouDewinView() }
        }
        // Reload "your area" when the phone moves about 1 km, or the backend changes.
        .task(id: areaKey) {
            if let coordinate = location.lastLocation?.coordinate { nearby.refresh(around: coordinate) }
        }
        // Live exposures (envlab) arrive one by one: fold each into Health and the map.
        .onChange(of: exposures.exposures.count) {
            if let coordinate = location.lastLocation?.coordinate { nearby.refresh(around: coordinate, force: true) }
            environment.reload()
        }
    }

    private var areaKey: String {
        guard let coordinate = location.lastLocation?.coordinate else { return "none|\(pipeline.backendDescription)" }
        return String(format: "%.2f,%.2f|", coordinate.latitude, coordinate.longitude) + pipeline.backendDescription
    }
}
