import MWDATInputs
import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(GlassesController.self) private var glasses
    @Environment(MealPipeline.self) private var pipeline
    @Environment(WakeWordListener.self) private var wakeWord
    @Environment(LocationReporter.self) private var location
    @AppStorage(UserProfile.firstNameKey) private var firstName = ""
    @Environment(EnvlabClient.self) private var envlab
    @Environment(ExposureStore.self) private var exposures
    @State private var envlabDraft = EnvlabSettings.current
    @Environment(\.modelContext) private var context

    @AppStorage(BackendSettings.modeKey) private var backendMode = BackendSettings.Mode.mock.rawValue
    @AppStorage(BackendSettings.urlKey) private var serverURL = ""
    @AppStorage(BackendSettings.tokenKey) private var serverToken = ""
    @AppStorage(ClaudeSettings.modelKey) private var claudeModel = ClaudeModel.opus.rawValue
    @State private var claudeKeyDraft = ""
    @State private var claudeHasKey = ClaudeSettings.hasKey
    @State private var claudeTestResult: String?
    @AppStorage(ClaudeSettings.foodAnalyzerKey) private var foodAnalyzer = "server"

    @AppStorage("goal.calories") private var goalCalories = Goals.defaults.calories
    @AppStorage("goal.protein") private var goalProtein = Goals.defaults.proteinG
    @AppStorage("goal.carbs") private var goalCarbs = Goals.defaults.carbsG
    @AppStorage("goal.fat") private var goalFat = Goals.defaults.fatG
    @AppStorage("goal.fiber") private var goalFiber = Goals.defaults.fiberG
    @AppStorage("goal.sugarMax") private var goalSugar = Goals.defaults.sugarMaxG
    @AppStorage("goal.sodiumMax") private var goalSodium = Goals.defaults.sodiumMaxMg

    #if DEBUG
    @State private var mockActive = MockGlassesKit.isActive
    #endif

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                glassesSection
                wakeWordSection
                locationSection
                envlabSection
                foodAnalysisSection
                backendSection
                goalsSection
                #if DEBUG
                debugSection
                #endif
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: Glasses

    private var glassesSection: some View {
        Section {
            LabeledContent("Registration", value: glasses.registrationState.description)
            LabeledContent("Glasses", value: glasses.hasActiveDevice ? "available" : "not found")
            LabeledContent("Session", value: String(describing: glasses.sessionState))
            LabeledContent("Camera", value: String(describing: glasses.streamState))
            LabeledContent("Buttons", value: String(describing: glasses.inputsState))
            LabeledContent("Last input", value: glasses.lastInput).font(.caption)

            Toggle("Keep camera on", isOn: Binding(
                get: { glasses.keepCameraWarm }, set: { glasses.keepCameraWarm = $0 }
            ))

            if !glasses.isRegistered {
                Button("Connect to Meta AI") { Task { await glasses.register() } }
            } else if glasses.wantsConnection {
                Button("Disconnect glasses", role: .destructive) { glasses.disconnect() }
            } else {
                Button("Start glasses") { glasses.connect() }
            }
            if let error = glasses.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Glasses")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(glasses.keepCameraWarm
                     ? "Faster captures, but the glasses' camera light stays on while connected."
                     : "The camera, and its light, turn on only while taking a photo. Double-press the capture button to log a meal.")
                if glasses.isRegistered {
                    Button("Unregister from Meta AI") { Task { await glasses.unregister() } }
                        .font(.caption)
                }
            }
        }
    }

    // MARK: Hey Dewin

    private var wakeWordSection: some View {
        Section {
            Toggle("Listen for \"Hey Dewin\"", isOn: Binding(
                get: { wakeWord.enabled }, set: { wakeWord.enabled = $0 }
            ))
            LabeledContent("Status", value: wakeWord.statusText)
            if !wakeWord.lastHeard.isEmpty {
                LabeledContent("Last heard", value: wakeWord.lastHeard).font(.caption)
            }
        } header: {
            Text("Hey Dewin")
        } footer: {
            Text("Recognized on the glasses with Meta's on-device speech (experimental). The first time, Meta AI asks for microphone permission.")
        }
    }

    // MARK: Profile

    private var profileSection: some View {
        Section {
            TextField("First name", text: $firstName)
                .textContentType(.givenName)
                .autocorrectionDisabled()
        } header: {
            Text("You")
        } footer: {
            Text("Used for \"Welcome back\" and on your 90-day report. Stays on this phone.")
        }
    }

    // MARK: Location

    private var locationSection: some View {
        @Bindable var location = location
        return Section {
            if location.isAuthorized {
                Toggle("Share my area", isOn: $location.sharing)
                LabeledContent("Last sent", value: location.lastPublished?.formatted(date: .omitted, time: .shortened) ?? "Not yet")
                if let error = location.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            } else {
                Button("Allow location") { location.requestPermission() }
                if location.authorization == .denied {
                    Text("Location is off for Dewin. Turn it on in the Settings app.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Air & Water")
        } footer: {
            Text("Sends your position rounded to about 1 km, so the server collects air and water sensor data for your area. It's sent when you move about 1 km or every 15 minutes while the app is open.")
        }
    }

    // MARK: Air & water data (envlab gateway)

    private var envlabSection: some View {
        Section {
            Picker("Source", selection: $envlabDraft.mode) {
                Text("Sample data").tag(EnvlabSettings.Mode.off)
                Text("Dewin sensors (live)").tag(EnvlabSettings.Mode.live)
            }
            if envlabDraft.mode == .live {
                TextField("https://dewin-api.cbnsndwch.dev", text: $envlabDraft.url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Personal API token (optional)", text: $envlabDraft.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button("Apply") {
                envlabDraft.save()
                envlab.apply(envlabDraft)
                location.precise = envlabDraft.mode == .live
            }
            .disabled(envlabDraft == EnvlabSettings.current)
            if envlabDraft.mode == .live {
                @Bindable var location = location
                Toggle("Use demo location (test sensors)", isOn: $location.useDemoLocation)
            }
            if EnvlabSettings.current.mode == .live {
                LabeledContent("Status", value: envlab.state).font(.caption)
                LabeledContent("Waiting to send", value: "\(envlab.pendingCount) fixes").font(.caption)
                LabeledContent("Exposures", value: "\(exposures.exposures.filter(\.isMatched).count) matched · \(exposures.exposures.filter { !$0.isMatched }.count) no nearby data")
                    .font(.caption)
                NavigationLink("Exposure details") { ExposureLogView() }
                if let error = envlab.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Air & water data")
        } footer: {
            Text(envlabDraft.mode == .live
                 ? "While Dewin is open, it sends your precise location every 5 seconds so the server can match you with Dewin sensors within 100 m. Fixes taken offline are kept and sent later. Your token stays in the Keychain. The demo location (25.7617, -80.1918) matches the team's simulated test sensors; real GPS isn't sent while it's on."
                 : "Sample data is generated on this phone so you can try Health and the map before the sensors are live.")
        }
    }

    // MARK: Food analysis

    private var foodAnalysisSection: some View {
        Section {
            Picker("Analyze photos with", selection: $foodAnalyzer) {
                Text("Dewin server").tag("server")
                Text("Claude").tag("claude")
            }
            .onChange(of: foodAnalyzer) { pipeline.foodAnalysisChanged() }
            if foodAnalyzer == "claude" {
                SecureField(claudeHasKey ? "API key saved (enter to replace)" : "Anthropic API key", text: $claudeKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Model", selection: $claudeModel) {
                    ForEach(ClaudeModel.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Button("Save key") {
                    ClaudeSettings.saveKey(claudeKeyDraft)
                    claudeKeyDraft = ""
                    claudeHasKey = ClaudeSettings.hasKey
                    claudeTestResult = nil
                    pipeline.foodAnalysisChanged()
                }
                .disabled(claudeKeyDraft.isEmpty)
                LabeledContent("Status", value: claudeHasKey ? "Ready · \(ClaudeModel(rawValue: claudeModel)?.label ?? "")" : "Needs an API key")
                    .font(.caption)
                if claudeHasKey {
                    LabeledContent("Saved key", value: ClaudeSettings.keyHint).font(.caption.monospaced())
                    Button("Test key") {
                        claudeTestResult = "Testing…"
                        Task { claudeTestResult = await ClaudeSettings.testKey() }
                    }
                    if let claudeTestResult {
                        Text(claudeTestResult).font(.caption)
                            .foregroundStyle(claudeTestResult == "Key works." ? Brand.aqua : .orange)
                    }
                }
                if claudeHasKey {
                    Button("Remove API key", role: .destructive) {
                        ClaudeSettings.saveKey("")
                        claudeHasKey = false
                    }
                }
            }
        } header: {
            Text("Food analysis")
        } footer: {
            Text(foodAnalyzer == "claude"
                 ? "Meal photos go from this phone to Anthropic's API with your key, and Claude estimates the items, portions and nutrition. The key stays in this phone's Keychain. Air, water and the report still use the server."
                 : "Meal photos go to the Dewin server (Backend below) for analysis.")
        }
    }

    // MARK: Backend

    private var backendSection: some View {
        Section {
            Picker("Backend", selection: $backendMode) {
                ForEach(BackendSettings.Mode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            if backendMode == BackendSettings.Mode.socket.rawValue {
                TextField("https://your-tunnel.example.com", text: $serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Token (optional)", text: $serverToken)
            }
            Button("Apply") { pipeline.applySettings(.current) }
            LabeledContent("Status", value: pipeline.backendDescription).font(.caption)
            LabeledContent("Client ID") {
                Text(BackendSettings.clientID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text("Backend")
        } footer: {
            Text("Socket.IO over WebSocket. The app emits meal:submit and location, asks env:query for air and water readings, and receives meal:status and meal:result. See docs/BACKEND_CONTRACT.md.")
        }
    }

    // MARK: Goals

    private var goalsSection: some View {
        Section("Daily goals") {
            goalField("Calories", $goalCalories, "cal", step: 50)
            goalField("Protein", $goalProtein, "g", step: 5)
            goalField("Carbs", $goalCarbs, "g", step: 5)
            goalField("Fat", $goalFat, "g", step: 5)
            goalField("Fiber", $goalFiber, "g", step: 1)
            goalField("Sugar (max)", $goalSugar, "g", step: 5)
            goalField("Sodium (max)", $goalSodium, "mg", step: 100)
        }
    }

    private func goalField(_ label: String, _ value: Binding<Double>, _ unit: String, step: Double) -> some View {
        Stepper(value: value, in: 0...10_000, step: step) {
            LabeledContent(label, value: "\(Int(value.wrappedValue)) \(unit)")
        }
    }

    // MARK: Debug

    #if DEBUG
    private var debugSection: some View {
        Section("Debug") {
            Toggle("Use mock glasses", isOn: $mockActive)
                .onChange(of: mockActive) { _, on in
                    if on { MockGlassesKit.start(); glasses.connect() } else { glasses.disconnect(); MockGlassesKit.stop() }
                }
            Button("Mock: press capture button") { MockGlassesKit.press(glasses.triggerPress) }
                .disabled(!mockActive)
            Button("Mock: say \"Hey Dewin\"") { MockGlassesKit.say("Hey Dewin, log this") }
            Button("Mock: ask calories today") { MockGlassesKit.say("Hey Dewin, how many calories did I eat today?") }
                .disabled(!mockActive)
            Button("Add a week of demo meals") { DemoData.seedWeek(into: context) }
            Button("Delete all meals", role: .destructive) { try? context.delete(model: Meal.self) }
        }
    }
    #endif
}
