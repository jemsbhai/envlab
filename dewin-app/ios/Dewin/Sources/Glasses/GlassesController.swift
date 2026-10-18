import Foundation
import MWDATCamera
import MWDATCore
import MWDATInputs
import MWDATSpeech
import Observation

/// Owns everything glasses-side: registration with Meta AI, the device session,
/// the camera, and the capture-button trigger. The rest of the app only sees
/// `capturePhoto()` and `onTrigger`.
///
/// Lifecycle, as the SDK requires it:
///   register (once, via Meta AI) → createSession → start → .started → camera permission
///   then per capture (on-demand): addCamera + stream.start → .streaming → capturePhoto → stop
@Observable
@MainActor
final class GlassesController {
    // MARK: State the UI binds to

    private(set) var registrationState: RegistrationState
    private(set) var hasActiveDevice = false
    private(set) var sessionState: DeviceSessionState = .idle
    private(set) var streamState: StreamState = .stopped
    private(set) var inputsState: InputsState = .inactive
    /// Last glasses input seen, verbatim. Useful on Gen 1, where which presses
    /// actually reach the app is still to be confirmed.
    private(set) var lastInput: String = "none"
    private(set) var lastError: String?

    /// True while the user wants the glasses connected. Drives auto-reconnect, and persists
    /// across launches so the app reconnects on its own after iOS closes it.
    private(set) var wantsConnection = UserDefaults.standard.object(forKey: GlassesController.autoConnectKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(wantsConnection, forKey: Self.autoConnectKey) }
    }
    static let autoConnectKey = "glassesAutoConnect"

    var isRegistered: Bool { registrationState == .registered }

    /// On-glasses speech recognition (experimental in the SDK), for the "Hey Dewin" phrase.
    private(set) var speechState: String = "off"
    /// Set by the wake-phrase listener. Attaches or detaches the recognizer on the live session.
    var listenForSpeech = false {
        didSet {
            guard listenForSpeech != oldValue else { return }
            if listenForSpeech { Task { await attachSpeech() } } else { tearDownSpeech() }
        }
    }
    /// Every transcription the glasses produce, partial and final.
    @ObservationIgnored var onTranscript: ((_ text: String, _ isFinal: Bool) -> Void)?
    /// Connected with camera permission: a capture can start the camera itself.
    var isReady: Bool { sessionState == .started && cameraPermissionGranted }

    /// Off (default): the camera, and the glasses' privacy LED, only turn on for each
    /// capture. On: the camera stays streaming for instant captures and the LED stays lit.
    var keepCameraWarm: Bool = UserDefaults.standard.bool(forKey: GlassesController.keepWarmKey) {
        didSet {
            UserDefaults.standard.set(keepCameraWarm, forKey: Self.keepWarmKey)
            if keepCameraWarm { startCamera() } else if !capturing { stopCamera() }
        }
    }
    static let keepWarmKey = "keepCameraWarm"

    private var cameraPermissionGranted = false

    /// How long the camera took to start for the last capture (zero when already warm).
    private(set) var lastCameraStartup: Duration = .zero

    /// Which capture-button press fires a describe. Double press by default, since a
    /// single press is the glasses' own "take a photo" and may never reach the app.
    var triggerPress: CapturePressType = .doublePress

    /// Called on the main actor when the wearer fires the trigger on the glasses.
    @ObservationIgnored var onTrigger: (() -> Void)?

    // MARK: Private

    @ObservationIgnored private let wearables: WearablesInterface
    @ObservationIgnored private let selector: AutoDeviceSelector
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var camera: MWDATCamera.Camera?
    @ObservationIgnored private var inputs: Inputs?
    @ObservationIgnored private var inputsWasActive = false
    @ObservationIgnored private var inputsDrain: Task<Void, Never>?
    @ObservationIgnored private var pendingPhoto: CheckedContinuation<Data, Error>?
    @ObservationIgnored private var capturing = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private let sessionTokens = ListenerTokenBag()
    @ObservationIgnored private let streamTokens = ListenerTokenBag()
    @ObservationIgnored private let inputsTokens = ListenerTokenBag()
    @ObservationIgnored private var speech: Speech?
    @ObservationIgnored private var speechHasStarted = false
    @ObservationIgnored private var speechRevival: Task<Void, Never>?
    @ObservationIgnored private let speechTokens = ListenerTokenBag()

    enum CaptureError: LocalizedError {
        case notReady, busy, failed(String), timedOut

        var errorDescription: String? {
            switch self {
            case .notReady: "Glasses aren't streaming yet."
            case .busy: "Already taking a photo."
            case let .failed(why): "Photo failed: \(why)"
            case .timedOut: "The glasses didn't send the photo in time."
            }
        }
    }

    init(wearables: WearablesInterface = Wearables.shared) {
        self.wearables = wearables
        self.selector = AutoDeviceSelector(wearables: wearables)
        self.registrationState = wearables.registrationState

        Task { [weak self] in
            for await state in wearables.registrationStateStream() {
                guard let self else { return }
                registrationState = state
                // Just registered (or the SDK finished loading): connect without a trip to Settings.
                if state == .registered, wantsConnection, session == nil {
                    log("registered, connecting")
                    startSession()
                }
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await deviceId in selector.activeDeviceStream() {
                hasActiveDevice = deviceId != nil
                // Glasses came back (unfolded, back in range): resume if we were connected.
                if hasActiveDevice, wantsConnection, session == nil { scheduleReconnect(after: .zero) }
            }
        }
    }

    // MARK: Registration (one-time, bounces through the Meta AI app)

    func register() async {
        do {
            try await wearables.startRegistration()
        } catch {
            report(error)
        }
    }

    func unregister() async {
        disconnect()
        do {
            try await wearables.startUnregistration()
        } catch {
            report(error)
        }
    }

    /// Pass Meta AI's callback URLs here (from `.onOpenURL`).
    func handle(url: URL) async {
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else { return }
        do {
            _ = try await wearables.handleUrl(url)
        } catch {
            report(error)
        }
    }

    // MARK: Connect / disconnect

    func connect() {
        wantsConnection = true
        lastError = nil
        startSession()
    }

    /// Call on launch and whenever the app comes back to the foreground. If the user wants the
    /// glasses connected and there's no session (iOS closed the app, Bluetooth dropped), start one.
    func resumeIfNeeded() {
        guard isRegistered, wantsConnection, session == nil else { return }
        log("resuming session")
        lastError = nil
        startSession()
    }

    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel()
        session?.stop()
    }

    private func startSession() {
        guard session == nil else { return }
        do throws(DeviceSessionError) {
            let newSession = try wearables.createSession(deviceSelector: selector)
            session = newSession
            // Subscribe before start() so no transitions are missed.
            newSession.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.sessionChanged(state) }
            }.store(in: sessionTokens)
            newSession.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.report(error) }
            }.store(in: sessionTokens)
            sessionState = .starting
            try newSession.start()
        } catch {
            report(error)
            tearDownSession()
            scheduleReconnect()
        }
    }

    private func sessionChanged(_ state: DeviceSessionState) {
        sessionState = state
        log("session \(state)")
        switch state {
        case .started:
            lastError = nil
            attachInputs()
            Task {
                guard await ensureCameraPermission() else { return }
                if keepCameraWarm { startCamera() }
                if listenForSpeech { await attachSpeech() }
            }
        case .stopped:
            tearDownSession()
            scheduleReconnect()
        default:
            break
        }
    }

    private func tearDownSession() {
        sessionTokens.clear()
        tearDownStream()
        tearDownInputs()
        tearDownSpeech()
        session = nil
        sessionState = .idle
    }

    /// Retries with a short delay while the user still wants the glasses connected.
    /// Device availability changes also trigger a reconnect (see init).
    private func scheduleReconnect(after delay: Duration = .seconds(3)) {
        guard wantsConnection else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, wantsConnection, session == nil, hasActiveDevice else { return }
            startSession()
        }
    }

    // MARK: Camera

    /// Asks Meta AI for camera access once per connection, so a capture never has to
    /// bounce out to the Meta AI app. Opens Meta AI only the first time.
    @discardableResult
    private func ensureCameraPermission() async -> Bool {
        if cameraPermissionGranted { return true }
        do {
            if try await wearables.checkPermissionStatus(.camera) != .granted,
               try await wearables.requestPermission(.camera) != .granted {
                lastError = "Camera permission was denied in Meta AI."
                return false
            }
        } catch {
            report(error)
            return false
        }
        cameraPermissionGranted = true
        return true
    }

    /// Adds the camera and starts its stream. The glasses' privacy LED is on for as
    /// long as this stream runs, so on-demand mode stops it right after each photo.
    private func startCamera() {
        guard let session, session.state == .started, camera == nil, cameraPermissionGranted else { return }
        // Lowest resolution and frame rate: the stream only exists to take photos
        // (which come back full-size regardless), and this keeps Bluetooth and battery use down.
        let config = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 2)
        do {
            guard let newCamera = try session.addCamera(config: config) else {
                lastError = "These glasses didn't offer a camera."
                return
            }
            camera = newCamera
            let stream = newCamera.stream
            stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.streamChanged(state) }
            }.store(in: streamTokens)
            stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.streamFailed(error) }
            }.store(in: streamTokens)
            stream.photoDataPublisher.listen { [weak self] photo in
                Task { @MainActor in self?.photoArrived(photo.data) }
            }.store(in: streamTokens)
            streamState = .starting
            stream.start()
        } catch {
            camera = nil
            report(error)
        }
    }

    /// Stops the camera (and the LED). The `.stopped` observer does the cleanup.
    private func stopCamera() {
        camera?.stop()
    }

    private func streamChanged(_ state: StreamState) {
        streamState = state
        log("stream \(state)")
        if state == .stopped {
            tearDownStream()
            // Always-on mode: the stream died on its own while the session lives on.
            if keepCameraWarm, wantsConnection, session?.state == .started {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.startCamera()
                }
            }
        }
    }

    private func streamFailed(_ error: StreamError) {
        if case .photoCaptureFailed = error {
            finishPhoto(.failure(CaptureError.failed(error.localizedDescription)))
        }
        report(error)
    }

    private func tearDownStream() {
        streamTokens.clear()
        camera?.stop()
        camera = nil
        streamState = .stopped
        finishPhoto(.failure(CaptureError.notReady))
    }

    /// Waits for the stream to reach `.streaming`, starting the camera if needed
    /// (and first letting a previous on-demand stop finish).
    private func waitForStreaming(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        var started = false
        while streamState != .streaming {
            guard ContinuousClock.now < deadline else { throw CaptureError.timedOut }
            guard session?.state == .started else { throw CaptureError.notReady }
            if camera == nil {
                if started { throw CaptureError.failed("the camera stopped while starting") }
                startCamera()
                started = true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Photo capture

    /// Takes a JPEG through the glasses camera. In on-demand mode this starts the
    /// camera, captures, and stops it again so the LED is only on for the capture.
    func capturePhoto(timeout: Duration = .seconds(15)) async throws -> Data {
        guard isReady else { throw CaptureError.notReady }
        guard pendingPhoto == nil, !capturing else { throw CaptureError.busy }
        capturing = true
        defer {
            capturing = false
            if !keepCameraWarm { stopCamera() }
            // A photo uses the file-transfer channel, which puts the speech recognizer down.
            reviveSpeech()
        }

        let warmup = ContinuousClock.now
        try await waitForStreaming(timeout: .seconds(10))
        lastCameraStartup = ContinuousClock.now - warmup
        guard let stream = camera?.stream else { throw CaptureError.notReady }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finishPhoto(.failure(CaptureError.timedOut))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pendingPhoto = continuation
            if !stream.capturePhoto(format: .jpeg) {
                finishPhoto(.failure(CaptureError.failed("the glasses refused the request")))
            }
        }
    }

    private func photoArrived(_ data: Data) {
        log("photo \(data.count) bytes")
        finishPhoto(.success(data))
    }

    private func finishPhoto(_ result: Result<Data, Error>) {
        guard let continuation = pendingPhoto else { return }
        pendingPhoto = nil
        continuation.resume(with: result)
    }

    // MARK: Speech (experimental in the SDK)

    /// Recognition runs on the glasses' own engine; only text crosses the link, so this
    /// doesn't use the phone's microphone or switch Bluetooth into call mode.
    private func attachSpeech() async {
        guard let session, session.state == .started, speech == nil, listenForSpeech else { return }
        do {
            // Opens Meta AI the first time, like the camera permission.
            if try await wearables.checkPermissionStatus(.microphone) != .granted,
               try await wearables.requestPermission(.microphone) != .granted {
                speechState = "microphone permission denied in Meta AI"
                return
            }
        } catch {
            speechState = "permission error: \(error.localizedDescription)"
            return
        }
        guard self.session === session, speech == nil, listenForSpeech else { return }

        let attached: Speech?
        do {
            attached = try session.addSpeech()
        } catch {
            speechState = "unavailable: \(error.description)"
            return
        }
        guard let attached else {
            speechState = "these glasses don't offer speech recognition"
            return
        }
        speech = attached
        speechHasStarted = false
        attached.transcriptionPublisher.listen { [weak self] result in
            Task { @MainActor in self?.onTranscript?(result.text, result.isFinal) }
        }.store(in: speechTokens)
        attached.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.speechChanged(state) }
        }.store(in: speechTokens)
        attached.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                self?.log("speech error \(error.description)")
                if error == .unavailable { self?.speechState = "unavailable on these glasses" }
            }
        }.store(in: speechTokens)
        speechState = "starting"
        // addSpeech leaves the recognizer stopped; it must be started explicitly.
        attached.start()
    }

    private func speechChanged(_ state: SpeechState) {
        log("speech \(state)")
        switch state {
        case .started:
            speechHasStarted = true
            speechState = "listening"
        case .stopped:
            // `stopped` is also the state it's born in; only restart one that was listening.
            guard speechHasStarted else { break }
            speechState = "stopped"
            reviveSpeech()
        default:
            break
        }
    }

    /// Starts the recognizer again after a photo (or anything else) put it down. `start()` is
    /// only honored once it's fully stopped, so retry for a few seconds.
    private func reviveSpeech() {
        guard speech != nil, speechRevival == nil else { return }
        speechRevival = Task { [weak self] in
            for _ in 1...8 {
                try? await Task.sleep(for: .milliseconds(750))
                guard let self, !Task.isCancelled, let speech = self.speech else { break }
                if speech.state == .started { break }
                if speech.state == .stopped, !self.capturing {
                    self.log("speech restarting")
                    speech.start()
                }
            }
            self?.speechRevival = nil
        }
    }

    private func tearDownSpeech() {
        speechRevival?.cancel()
        speechRevival = nil
        speechTokens.clear()
        speech?.stop()
        if speech != nil { try? session?.removeSpeech() }
        speech = nil
        speechHasStarted = false
        speechState = "off"
    }

    // MARK: Glasses inputs (experimental in the SDK)

    private func attachInputs() {
        guard let session, inputs == nil else { return }
        let config = InputsConfiguration(sources: [.captureButton, .captouch, .actionButton], consumeBack: false)
        let attached: Inputs?
        do {
            attached = try session.addInputs(configuration: config)
        } catch {
            lastInput = "unavailable: \(error.description)"
            return
        }
        guard let attached else {
            lastInput = "these glasses report no inputs"
            return
        }
        inputs = attached
        inputsWasActive = false

        inputsDrain = Task { [weak self] in
            for await event in attached.events {
                self?.received(event)
            }
        }
        attached.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.inputsChanged(state) }
        }.store(in: inputsTokens)
        attached.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.lastInput = "error: \(error.description)" }
        }.store(in: inputsTokens)
    }

    private func inputsChanged(_ state: InputsState) {
        inputsState = state
        log("inputs \(state)")
        switch state {
        case .active:
            inputsWasActive = true
        case .inactive where inputsWasActive:
            // Taking a photo uses the file-transfer channel, which drops the inputs
            // capability. It doesn't come back by itself: remove it and attach again.
            reattachInputs()
        default:
            break
        }
    }

    private func reattachInputs() {
        tearDownInputs()
        try? session?.removeInputs()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.attachInputs()
        }
    }

    private func tearDownInputs() {
        inputsDrain?.cancel()
        inputsDrain = nil
        inputsTokens.clear()
        inputs = nil
        inputsWasActive = false
        inputsState = .inactive
    }

    private func received(_ event: InputEvent) {
        lastInput = String(describing: event)
        log("input \(lastInput)")
        if case let .capture(press, _, _) = event, press == triggerPress {
            onTrigger?()
        }
    }

    // MARK: Errors

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        log("error \(lastError ?? "")")
    }

    private func log(_ message: String) {
        NSLog("[Glasses] %@", message)
    }
}
