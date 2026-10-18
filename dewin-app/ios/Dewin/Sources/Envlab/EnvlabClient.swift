import CoreLocation
import Foundation
import Observation
import Security
import SocketIO

/// Settings for the team's envlab gateway (Settings → Air & water data). Mode and URL live in
/// UserDefaults; the personal token lives in the Keychain and never goes into logs or URLs.
struct EnvlabSettings: Equatable {
    static let modeKey = "envlab.mode"
    static let urlKey = "envlab.url"
    static let defaultURL = "https://dewin-api.cbnsndwch.dev"

    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case off, live
        var id: String { rawValue }
    }

    var mode: Mode
    var url: String
    var token: String

    init(mode: Mode = .off, url: String = EnvlabSettings.defaultURL, token: String = "") {
        self.mode = mode
        self.url = url
        self.token = token
    }

    static var current: EnvlabSettings {
        let defaults = UserDefaults.standard
        return EnvlabSettings(
            mode: Mode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .live,
            url: defaults.string(forKey: urlKey) ?? defaultURL,
            token: EnvlabKeychain.read() ?? ""
        )
    }

    func save() {
        let previous = Self.current
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(url, forKey: Self.urlKey)
        EnvlabKeychain.write(token)
        // Another server or account has another history: the next connect syncs it from scratch.
        if previous.url != url || previous.token != token {
            defaults.removeObject(forKey: EnvlabClient.lastSyncedKey)
        }
    }
}

extension EnvlabLocationUpdate {
    /// A new fix to send: fresh event ID, the fix's own timestamp, full-precision coordinates.
    init(location: CLLocation) {
        self.init(
            measuredAt: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracyM: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        )
    }
}

/// What `syncHistory` brought back.
struct EnvlabSyncResult: Sendable, Equatable {
    var items = 0
    var pages = 0
    /// False when a page failed (timeout, error ACK, disconnect); the range should be asked again.
    var complete = true
}

/// The app's connection to the team's envlab Socket.IO API (envlab repo: backend/docs/api-v1.md).
///
/// Producer: precise GPS fixes (`location:update`), queued on disk and sent one at a time with
/// retries until the server acks them. Consumer: exposures pushed live (`exposure:update`) and the
/// disconnect gap read back from `exposure:history` on every (re)connect, both into `ExposureStore`.
@Observable
@MainActor
final class EnvlabClient {
    /// What the open demo gateway accepts in place of a personal token.
    static let openToken = "0"

    nonisolated static let lastSyncedKey = "envlab.lastSyncedAt"
    static let ackTimeout: Double = 10
    static let retryDelays: [Double] = [1, 2, 5, 10, 30]
    /// The API allows two submissions a second per user; stay a little under.
    static let minSubmitInterval: TimeInterval = 0.6
    static let maxPending = 2_000
    /// The server rejects fixes older than 90 days.
    static let maxFixAge: TimeInterval = 89 * 86_400
    static let historyWindow: TimeInterval = 31 * 86_400
    static let historyPageLimit = 200
    static let firstSyncLookback: TimeInterval = 7 * 86_400

    /// Running totals since launch, for the self-test and debugging.
    struct Counters: Sendable, Equatable {
        var acks = 0
        var duplicates = 0
        var retries = 0
        var dropped = 0
        var exposures = 0
        var historyItems = 0
        var historyPages = 0
    }

    /// Connection state for Settings: "off", "connecting", "connected", "error: …", …
    private(set) var state = "off"
    private(set) var isConnected = false
    /// Fixes stored on the phone that the server hasn't acked yet.
    private(set) var pendingCount = 0
    /// The last request failure (a dropped fix or a failed history page). Connection errors go in `state`.
    private(set) var lastError: String?
    private(set) var lastAckAt: Date?
    private(set) var lastExposureAt: Date?
    /// History is complete up to here; the next (re)connect asks from here to now.
    private(set) var lastSyncedAt: Date?
    private(set) var counters = Counters()

    var matchedCount: Int { store.exposures.lazy.filter(\.isMatched).count }
    var noMatchCount: Int { store.exposures.count - matchedCount }

    @ObservationIgnored let store: ExposureStore
    @ObservationIgnored private var settings: EnvlabSettings?
    @ObservationIgnored private var manager: SocketManager?
    @ObservationIgnored private var host = ""
    /// Bumped on every start and stop, so work from an older connection stops touching state.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var rejected = false
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var syncingGap = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lastSubmit: TimeInterval = 0
    @ObservationIgnored private let queueURL: URL
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "io.occh.dewin.envlab.queue", qos: .utility)
    @ObservationIgnored private var pending: [EnvlabLocationUpdate] = [] {
        didSet { pendingCount = pending.count }
    }

    init(store: ExposureStore, queueURL: URL = EnvlabFiles.url("pending-fixes.json")) {
        self.store = store
        self.queueURL = queueURL
        let cutoff = Date().addingTimeInterval(-Self.maxFixAge)
        let saved = EnvlabFiles.read([EnvlabLocationUpdate].self, from: queueURL) ?? []
        pending = Array(saved.filter { $0.measuredAt >= cutoff && $0.isValid }.suffix(Self.maxPending))
        pendingCount = pending.count
        lastSyncedAt = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date
        if !pending.isEmpty { log("\(pending.count) fixes waiting from last time") }
    }

    // MARK: Lifecycle

    /// Uses new settings; reconnects if they changed. `.off` disconnects.
    func apply(_ settings: EnvlabSettings) {
        if let current = self.settings, current == settings { return }
        stop()
        self.settings = settings
        if settings.mode == .live { start() }
    }

    func start() {
        guard let settings, settings.mode == .live else { state = "off"; return }
        if let manager {
            if !isConnected { manager.reconnect() }
            return
        }
        guard let url = Self.socketURL(settings.url) else {
            state = "error: invalid URL"
            log("invalid URL")
            return
        }
        // The gateway is open for the demo: with no personal token, connect as "0".
        let entered = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = entered.isEmpty ? Self.openToken : entered
        guard !token.isEmpty else {
            state = "error: no token"
            log("no token; not connecting")
            return
        }
        session += 1
        rejected = false
        host = url.port.map { "\(url.host() ?? ""):\($0)" } ?? url.host() ?? ""
        let manager = SocketManager(socketURL: url, config: [
            .version(.three), // Socket.IO 3/4, Engine.IO 4
            .path("/socket.io/"),
            .forceWebsockets(true),
            .log(false),
            .reconnects(true),
            .reconnectWait(1),
            .reconnectWaitMax(30),
            // Starscream's default Origin is "ws(s)://host", which python-socketio's origin check
            // (the mock, and the gateway's API_ALLOWED_ORIGINS) refuses. Send the http(s) origin.
            .extraHeaders(["Origin": Self.origin(of: url)]),
        ])
        self.manager = manager
        addHandlers(manager.defaultSocket, session: session)
        state = "connecting"
        log("connecting to \(url.scheme ?? "")://\(host)")
        manager.defaultSocket.connect(withPayload: ["token": token])
    }

    func stop() {
        session += 1
        if let manager {
            manager.defaultSocket.removeAllHandlers()
            manager.disconnect()
            log("disconnected")
        }
        manager = nil
        isConnected = false
        flushing = false
        syncingGap = false
        state = "off"
    }

    /// The Socket.IO origin: http(s), or ws(s) turned into http(s).
    static func socketURL(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("wss://") { text = "https://" + text.dropFirst(6) }
        if text.hasPrefix("ws://") { text = "http://" + text.dropFirst(5) }
        guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http", url.host() != nil else { return nil }
        return url
    }

    /// "https://dewin-api.cbnsndwch.dev", "http://127.0.0.1:8765".
    static func origin(of url: URL) -> String {
        "\(url.scheme ?? "https")://\(url.host() ?? "")" + (url.port.map { ":\($0)" } ?? "")
    }

    // MARK: Producer

    /// Queues a precise fix (new event ID, the fix's own timestamp) and sends it when connected.
    func send(_ location: CLLocation) {
        enqueue(EnvlabLocationUpdate(location: location))
    }

    /// Queues an update as is. Re-queuing one already sent is safe: the server answers `duplicate`.
    @discardableResult
    func enqueue(_ update: EnvlabLocationUpdate) -> Bool {
        guard settings?.mode == .live else { return false }
        guard update.isValid, update.measuredAt >= Date().addingTimeInterval(-Self.maxFixAge) else {
            log("skipped an invalid or too old fix")
            return false
        }
        pending.append(update)
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        saveQueue()
        flush()
        return true
    }

    /// Sends queued fixes one at a time while connected.
    private func flush() {
        guard !flushing, isConnected, !pending.isEmpty else { return }
        flushing = true
        let session = session
        Task { [weak self] in
            await self?.drainQueue(session: session)
            if let self, self.session == session { self.flushing = false }
        }
    }

    private enum Outcome {
        case accepted(EnvlabAck)
        case retry(String)
        case drop(String)
    }

    private func drainQueue(session: Int) async {
        while self.session == session, isConnected, let fix = pending.first {
            if fix.measuredAt < Date().addingTimeInterval(-Self.maxFixAge) {
                remove(fix)
                counters.dropped += 1
                continue
            }
            // At most two submissions a second, retries included.
            let wait = Self.minSubmitInterval - (ProcessInfo.processInfo.systemUptime - lastSubmit)
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                continue
            }
            lastSubmit = ProcessInfo.processInfo.systemUptime
            let outcome = await submit(fix)
            guard self.session == session else { return }
            switch outcome {
            case let .accepted(ack):
                remove(fix)
                failures = 0
                lastAckAt = .now
                counters.acks += 1
                if ack.duplicate == true { counters.duplicates += 1 }
                log("fix \(Self.short(fix.eventId)) accepted\(ack.duplicate == true ? " (duplicate)" : ""), \(pending.count) waiting")
            case let .retry(reason):
                let delay = Self.retryDelays[min(failures, Self.retryDelays.count - 1)]
                failures += 1
                counters.retries += 1
                log("fix \(Self.short(fix.eventId)) not accepted (\(reason)); retrying in \(Int(delay)) s")
                try? await Task.sleep(for: .seconds(delay))
            case let .drop(reason):
                remove(fix)
                failures = 0
                counters.dropped += 1
                lastError = "A location fix was rejected: \(reason)"
                log("fix \(Self.short(fix.eventId)) dropped: \(reason)")
            }
        }
    }

    private func submit(_ fix: EnvlabLocationUpdate) async -> Outcome {
        let payload: [String: Any]
        do {
            payload = try EnvlabCoding.jsonObject(fix)
        } catch {
            return .drop("couldn't encode")
        }
        switch await request(EnvlabLocationUpdate.event, payload) {
        case .notConnected:
            return .retry("not connected")
        case .timeout:
            return .retry("no ACK in \(Int(Self.ackTimeout)) s")
        case let .reply(reply):
            guard let ack = try? EnvlabCoding.decode(EnvlabAck.self, from: reply) else { return .retry("unreadable ACK") }
            if ack.ok { return .accepted(ack) }
            guard let error = ack.error else { return .drop("rejected without a reason") }
            // UNAUTHORIZED: keep the fix; it can go once the token is fixed.
            if error.isRetryable || error.code == "UNAUTHORIZED" { return .retry(error.code) }
            return .drop(error.summary) // INVALID_PAYLOAD, EVENT_ID_CONFLICT, …
        }
    }

    /// Removes the first queued copy of this fix (the same event can be queued twice).
    private func remove(_ fix: EnvlabLocationUpdate) {
        guard let index = pending.firstIndex(where: { $0.eventId == fix.eventId }) else { return }
        pending.remove(at: index)
        saveQueue()
    }

    private func saveQueue() {
        let snapshot = pending
        let url = queueURL
        ioQueue.async { EnvlabFiles.write(snapshot, to: url) }
    }

    // MARK: Consumer

    /// Reads `[from, to)` from `exposure:history` into the store: 31-day windows, 200 per page,
    /// following `nextCursor`. An `INVALID_CURSOR` restarts that window once without a cursor.
    @discardableResult
    func syncHistory(from: Date, to: Date) async -> EnvlabSyncResult {
        var result = EnvlabSyncResult()
        var start = from
        while start < to {
            let end = min(start.addingTimeInterval(Self.historyWindow), to)
            if !(await syncWindow(from: start, to: end, into: &result)) { result.complete = false }
            start = end
        }
        return result
    }

    private func syncWindow(from: Date, to: Date, into result: inout EnvlabSyncResult) async -> Bool {
        var cursor: String?
        var restarted = false
        while true {
            let query = EnvlabHistoryRequest(requestId: UUID().uuidString.lowercased(), from: from, to: to,
                                             limit: Self.historyPageLimit, cursor: cursor)
            guard let payload = try? EnvlabCoding.jsonObject(query) else { return false }
            switch await request(EnvlabHistoryRequest.event, payload) {
            case .notConnected:
                return false
            case .timeout:
                lastError = "History didn't answer in \(Int(Self.ackTimeout)) s."
                log("history page timed out")
                return false
            case let .reply(reply):
                let page: EnvlabHistoryPage
                do {
                    page = try EnvlabCoding.decode(EnvlabHistoryPage.self, from: reply)
                } catch {
                    lastError = "History reply couldn't be read."
                    log("unreadable history page: \(error)")
                    return false
                }
                if page.ok {
                    let items = page.items ?? []
                    store.upsert(contentsOf: items)
                    result.items += items.count
                    result.pages += 1
                    counters.historyItems += items.count
                    counters.historyPages += 1
                    guard let next = page.nextCursor, !next.isEmpty else { return true }
                    cursor = next
                } else if page.error?.code == "INVALID_CURSOR", cursor != nil, !restarted {
                    log("history cursor expired; restarting that window")
                    restarted = true
                    cursor = nil
                } else {
                    let reason = page.error?.summary ?? "rejected"
                    lastError = "History: \(reason)"
                    log("history failed: \(reason)")
                    return false
                }
            }
        }
    }

    /// After every (re)connect: history from `lastSyncedAt` (7 days on first run) to now.
    private func syncGap(session: Int) async {
        guard !syncingGap else { return }
        syncingGap = true
        defer { if self.session == session { syncingGap = false } }
        let started = Date()
        let from = lastSyncedAt ?? started.addingTimeInterval(-Self.firstSyncLookback)
        // Fixes still queued were taken before now but aren't enriched yet; ask for them next time too.
        let oldestPending = pending.map(\.measuredAt).min()
        let result = await syncHistory(from: from, to: started)
        guard self.session == session else { return }
        log("gap sync from \(EnvlabCoding.string(from: from)): \(result.items) items in \(result.pages) pages\(result.complete ? "" : ", incomplete")")
        guard result.complete else { return }
        let synced = min(started, oldestPending ?? started)
        lastSyncedAt = synced
        UserDefaults.standard.set(synced, forKey: Self.lastSyncedKey)
    }

    private func receive(_ payload: Any?) {
        do {
            let exposure = try EnvlabCoding.decode(Exposure.self, from: payload)
            store.upsert(exposure)
            lastExposureAt = .now
            counters.exposures += 1
            log("exposure \(Self.short(exposure.exposureId)) \(exposure.status) for fix \(Self.short(exposure.locationEventId)), \(exposure.sensors.count) sensors")
        } catch {
            log("unreadable exposure:update: \(error)")
        }
    }

    // MARK: Socket.IO

    private func addHandlers(_ socket: SocketIOClient, session: Int) {
        // Registered before connecting: an exposure can arrive before the fix's ACK.
        socket.on("exposure:update") { [weak self] data, _ in
            MainActor.assumeIsolated {
                guard let self, self.session == session else { return }
                self.receive(data.first)
            }
        }
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.session == session else { return }
                self.isConnected = true
                self.rejected = false
                self.failures = 0
                self.state = "connected"
                self.log("connected to \(self.host)")
                self.flush()
                Task { await self.syncGap(session: session) }
            }
        }
        socket.on(clientEvent: .disconnect) { [weak self] data, _ in
            MainActor.assumeIsolated {
                guard let self, self.session == session else { return }
                self.isConnected = false
                if !self.rejected { self.state = "disconnected" }
                self.log("disconnected: \(data.first.map { String(describing: $0) } ?? "")")
            }
        }
        socket.on(clientEvent: .reconnectAttempt) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.session == session, !self.rejected else { return }
                self.isConnected = false
                self.state = "reconnecting"
            }
        }
        // connect_error (the server refused the token) and transport errors. Not request errors.
        socket.on(clientEvent: .error) { [weak self] data, _ in
            MainActor.assumeIsolated {
                guard let self, self.session == session else { return }
                let message = ((data.first as? [String: Any])?["message"] as? String)
                    ?? data.first.map { String(describing: $0) } ?? "unknown"
                let text = message.count > 80 ? String(message.prefix(80)) + "…" : message
                self.log("connection error: \(text)")
                if message.contains("UNAUTHORIZED") {
                    // Retrying the same token won't help; wait for new settings.
                    self.rejected = true
                    self.isConnected = false
                    self.state = "error: token rejected (UNAUTHORIZED)"
                    self.manager?.reconnects = false
                    self.manager?.disconnect()
                } else if !self.isConnected {
                    self.state = "error: \(text)"
                }
            }
        }
    }

    private enum Reply {
        case reply(Any?)
        case timeout
        case notConnected
    }

    /// `emitWithAck(...).timingOut(after: 10)` as async. Also times out on its own: the library
    /// drops its timer when the socket goes away, which would leave the caller waiting forever.
    private func request(_ event: String, _ payload: [String: Any]) async -> Reply {
        guard isConnected, let socket = manager?.defaultSocket else { return .notConnected }
        let timeout = Self.ackTimeout
        return await withCheckedContinuation { continuation in
            let gate = ReplyGate(continuation)
            socket.emitWithAck(event, payload).timingOut(after: timeout) { data in
                MainActor.assumeIsolated {
                    if let first = data.first as? String, first == SocketAckStatus.noAck.rawValue {
                        gate.resume(.timeout)
                    } else {
                        gate.resume(.reply(data.first))
                    }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout + 1))
                gate.resume(.timeout)
            }
        }
    }

    /// Resumes a continuation once; later calls do nothing.
    @MainActor
    private final class ReplyGate {
        private var continuation: CheckedContinuation<Reply, Never>?
        init(_ continuation: CheckedContinuation<Reply, Never>) { self.continuation = continuation }
        func resume(_ reply: Reply) {
            continuation?.resume(returning: reply)
            continuation = nil
        }
    }

    private func log(_ message: String) {
        NSLog("[Envlab] %@", message)
    }

    private static func short(_ id: String) -> String { String(id.prefix(8)) }
}

/// The personal token, in the Keychain (service "io.occh.dewin.envlab").
private enum EnvlabKeychain {
    static let service = "io.occh.dewin.envlab"
    static let account = "token"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ token: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard !token.isEmpty else { return }
        var item = match
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { NSLog("[Envlab] couldn't save the token to the Keychain (%d)", status) }
    }
}
