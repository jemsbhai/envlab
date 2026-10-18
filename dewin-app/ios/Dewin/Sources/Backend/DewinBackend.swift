import Foundation
import SocketIO

/// What the backend tells the app, independent of transport.
enum BackendEvent: Sendable {
    case status(MealStatusMessage)
    case result(MealResultMessage)
}

/// The app's one connection to the Dewin server. Socket.IO is the real one; the mock lets the
/// app run end to end before the server is reachable.
///
/// Producer side (no API, the app just emits): meal photos and location pings.
/// Consumer side (an API): meal results the server pushes, and environment readings
/// requested with `env:query` and answered through the Socket.IO acknowledgement.
@MainActor
protocol DewinBackend: AnyObject {
    var connectionDescription: String { get }
    var isConnected: Bool { get }
    var onEvent: ((BackendEvent) -> Void)? { get set }
    var onConnectionChange: (() -> Void)? { get set }

    func start()
    func stop()
    /// Returns once the server has acknowledged the meal (stored it).
    func submit(_ meal: MealSubmit) async throws
    /// Tells the server where this phone is, so it collects air and water data nearby.
    func publishLocation(_ ping: LocationPing) async throws
    /// Asks for air and water readings inside a map area over a time range.
    func queryEnvironment(_ query: EnvQuery) async throws -> EnvSeries
    /// The "How you dewin?" exposure report for the last `days` days (`report:get`).
    func fetchReport(_ request: ReportRequest) async throws -> ExposureReport
    /// Deletes everything the server holds for this client ID (`data:delete`). Returns once confirmed.
    func deleteMyData(clientId: String) async throws
}

/// User-editable connection settings (Settings tab, persisted in UserDefaults).
struct BackendSettings: Equatable {
    static let modeKey = "backendMode"
    static let urlKey = "serverURL"
    static let tokenKey = "serverToken"
    static let clientIDKey = "clientID"

    enum Mode: String, CaseIterable, Identifiable {
        case mock, socket
        var id: String { rawValue }
        var label: String { self == .mock ? "Mock (on device)" : "Socket.IO (Pi)" }
    }

    var mode: Mode
    var url: String
    var token: String

    static var current: BackendSettings {
        let defaults = UserDefaults.standard
        return BackendSettings(
            mode: Mode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .mock,
            url: defaults.string(forKey: urlKey) ?? "",
            token: defaults.string(forKey: tokenKey) ?? ""
        )
    }

    /// One UUID per install; the server keys a phone's meals and pending results by it.
    static var clientID: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: clientIDKey) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: clientIDKey)
        return id
    }
}

enum BackendError: LocalizedError {
    case notConnected
    case timeout(String)
    case rejected(String)
    case badReply(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the server."
        case let .timeout(event): "The server didn't answer \(event) in time."
        case let .rejected(message): message
        case let .badReply(event): "The server's answer to \(event) couldn't be read."
        }
    }
}

/// Socket.IO over the Cloudflare Tunnel (WebSocket transport). Events, see BACKEND_CONTRACT.md:
/// - emit `meal:submit` (JSON + binary JPEG), acked when stored
/// - emit `location`, no ack
/// - emit `env:query`, the ack carries the readings
/// - on `meal:status`, on `meal:result` (acked so the server stops resending)
@MainActor
final class SocketIOBackend: DewinBackend {
    var onEvent: ((BackendEvent) -> Void)?
    var onConnectionChange: (() -> Void)?

    private let url: URL
    private let clientID: String
    private let manager: SocketManager
    private var socket: SocketIOClient { manager.defaultSocket }
    private var state = "disconnected" { didSet { if state != oldValue { onConnectionChange?() } } }
    private(set) var isConnected = false { didSet { if isConnected != oldValue { onConnectionChange?() } } }

    init?(settings: BackendSettings, clientID: String) {
        var text = settings.url.trimmingCharacters(in: .whitespaces)
        // Socket.IO wants the http(s) origin; accept ws(s) too.
        if text.hasPrefix("wss://") { text = "https://" + text.dropFirst(6) }
        if text.hasPrefix("ws://") { text = "http://" + text.dropFirst(5) }
        guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http", url.host() != nil else { return nil }
        self.url = url
        self.clientID = clientID
        var config: SocketIOClientConfiguration = [
            .log(false),
            .compress,
            .forceWebsockets(true),
            .reconnects(true),
            .reconnectWait(1),
            .reconnectWaitMax(30),
            .connectParams(["clientId": clientID]),
        ]
        if !settings.token.isEmpty {
            config.insert(.extraHeaders(["Authorization": "Bearer \(settings.token)"]))
        }
        manager = SocketManager(socketURL: url, config: config)
        authToken = settings.token
        addHandlers()
    }

    private let authToken: String

    var connectionDescription: String { "\(url.host() ?? url.absoluteString): \(state)" }

    func start() {
        state = "connecting"
        // Socket.IO v3+/v4 handshake auth; the server reads socket.handshake.auth.
        var auth: [String: Any] = ["clientId": clientID, "app": "dewin-ios", "schema": 1]
        if !authToken.isEmpty { auth["token"] = authToken }
        socket.connect(withPayload: auth)
    }

    func stop() {
        manager.disconnect()
        isConnected = false
        state = "disconnected"
    }

    // MARK: Producer

    func submit(_ meal: MealSubmit) async throws {
        let reply = try await emitWithAck("meal:submit", meal.payload, timeout: 30)
        try Self.checkOK(reply)
        NSLog("[Backend] meal %@ accepted", meal.mealId)
    }

    func publishLocation(_ ping: LocationPing) async throws {
        guard isConnected else { throw BackendError.notConnected }
        socket.emit("location", try Self.dictionary(ping))
    }

    // MARK: Consumer

    func queryEnvironment(_ query: EnvQuery) async throws -> EnvSeries {
        let reply = try await emitWithAck("env:query", try Self.dictionary(query), timeout: 15)
        guard let series = Self.decode(EnvSeries.self, from: reply) else { throw BackendError.badReply("env:query") }
        if let error = series.error { throw EnvError.server(error) }
        return series
    }

    func fetchReport(_ request: ReportRequest) async throws -> ExposureReport {
        let reply = try await emitWithAck(ReportRequest.event, try Self.dictionary(request), timeout: 20)
        if let object = reply as? [String: Any], let error = object["error"] as? String { throw BackendError.rejected(error) }
        guard let report = Self.decode(ExposureReport.self, from: reply) else { throw BackendError.badReply(ReportRequest.event) }
        return report
    }

    func deleteMyData(clientId: String) async throws {
        let reply = try await emitWithAck("data:delete", ["schema": "dewin.data.delete/1", "clientId": clientId], timeout: 20)
        try Self.checkOK(reply)
    }

    private func addHandlers() {
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isConnected = true
                self.state = "connected"
                NSLog("[Backend] socket.io connected to %@", self.url.absoluteString)
            }
        }
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.isConnected = false; self?.state = "disconnected" }
        }
        socket.on(clientEvent: .reconnectAttempt) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.isConnected = false; self?.state = "reconnecting" }
        }
        socket.on(clientEvent: .error) { [weak self] data, _ in
            MainActor.assumeIsolated {
                let text = data.first.map { String(describing: $0) } ?? "unknown"
                NSLog("[Backend] socket.io error: %@", text)
                self?.state = "error: \(text.count > 80 ? String(text.prefix(80)) + "…" : text)"
            }
        }
        socket.on("meal:status") { [weak self] data, _ in
            MainActor.assumeIsolated {
                guard let status = Self.decode(MealStatusMessage.self, from: data.first) else { return }
                self?.onEvent?(.status(status))
            }
        }
        socket.on("meal:result") { [weak self] data, ack in
            MainActor.assumeIsolated {
                if let result = Self.decode(MealResultMessage.self, from: data.first) {
                    self?.onEvent?(.result(result))
                    ack.with(["ok": true, "mealId": result.mealId])
                } else {
                    // A malformed result will never parse; ack it so the server stops resending.
                    NSLog("[Backend] bad meal:result %@", String(describing: data.first))
                    ack.with(["ok": false, "error": "unreadable result"])
                }
            }
        }
    }

    private func emitWithAck(_ event: String, _ payload: [String: Any], timeout: Double) async throws -> Any? {
        guard isConnected else { throw BackendError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            socket.emitWithAck(event, payload).timingOut(after: timeout) { data in
                if let first = data.first as? String, first == SocketAckStatus.noAck.rawValue {
                    continuation.resume(throwing: BackendError.timeout(event))
                } else {
                    continuation.resume(returning: data.first)
                }
            }
        }
    }

    // MARK: JSON ⇄ Socket.IO payloads

    /// Socket.IO sends JSON objects; route Codable types through JSON so dates match the contract.
    static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try ContractCoding.encoder.encode(value)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func decode<T: Decodable>(_ type: T.Type, from payload: Any?) -> T? {
        let data: Data?
        switch payload {
        case let string as String: data = Data(string.utf8)
        case let object? where JSONSerialization.isValidJSONObject(object): data = try? JSONSerialization.data(withJSONObject: object)
        default: data = nil
        }
        guard let data else { return nil }
        do {
            return try ContractCoding.decoder.decode(type, from: data)
        } catch {
            NSLog("[Backend] decode %@ failed: %@", String(describing: type), String(describing: error))
            return nil
        }
    }

    private static func checkOK(_ reply: Any?) throws {
        guard let object = reply as? [String: Any] else { return }
        if let error = object["error"] as? String { throw BackendError.rejected(error) }
        if let ok = object["ok"] as? Bool, !ok { throw BackendError.rejected("The server said no.") }
    }
}

// MARK: - Mock

/// Answers on device with plausible, varied meals so every screen has realistic data.
/// It does not look at the photo.
@MainActor
final class MockBackend: DewinBackend {
    var onEvent: ((BackendEvent) -> Void)?
    var onConnectionChange: (() -> Void)?
    var isConnected: Bool { true }
    var connectionDescription: String { "mock: answers on device, ignores the photo" }

    func start() {}
    func stop() {}

    func publishLocation(_ ping: LocationPing) async throws {
        NSLog("[Backend] mock location %.3f,%.3f", ping.lat, ping.lon)
    }

    func queryEnvironment(_ query: EnvQuery) async throws -> EnvSeries {
        try? await Task.sleep(for: .milliseconds(250))
        return MockEnvironment.series(for: query)
    }

    func fetchReport(_ request: ReportRequest) async throws -> ExposureReport {
        try? await Task.sleep(for: .milliseconds(300))
        return MockReport.sample(days: request.days)
    }

    func deleteMyData(clientId: String) async throws {
        NSLog("[Backend] mock data:delete for %@", clientId)
    }

    func submit(_ meal: MealSubmit) async throws {
        let mealID = meal.mealId
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.onEvent?(.status(.init(schema: "dewin.meal.status/1", mealId: mealID, stage: "analyzing")))
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self?.onEvent?(.result(Self.sample(for: mealID)))
        }
    }

    static func sample(for mealID: String) -> MealResultMessage {
        typealias Item = MealResultMessage.Item
        func n(_ cal: Double, _ p: Double, _ c: Double, _ f: Double, _ fib: Double, _ sug: Double, _ na: Double) -> Nutrients {
            Nutrients(calories: cal, proteinG: p, carbsG: c, fatG: f, fiberG: fib, sugarG: sug, sodiumMg: na)
        }
        let menu: [(String, [Item], Double, [String], String)] = [
            ("Grilled chicken salad",
             [Item(name: "Grilled chicken breast", portion: "150 g", nutrients: n(248, 46, 0, 5, 0, 0, 110)),
              Item(name: "Mixed greens and vegetables", portion: "2 cups", nutrients: n(60, 3, 11, 0.5, 5, 5, 60)),
              Item(name: "Vinaigrette", portion: "2 tbsp", nutrients: n(147, 0, 7, 15, 0, 3, 450))],
             84, ["high-protein", "high-fiber"], "Great protein. The dressing is most of the sodium, so try it on the side."),
            ("Pepperoni pizza",
             [Item(name: "Pepperoni pizza", portion: "2 slices", nutrients: n(620, 26, 68, 27, 4, 8, 1480))],
             38, ["high-sodium", "refined-carbs"], "Two slices is about two thirds of a day's sodium. Add a side salad for fiber."),
            ("Greek yogurt with berries",
             [Item(name: "Greek yogurt, plain", portion: "170 g", nutrients: n(100, 17, 6, 0.7, 0, 6, 60)),
              Item(name: "Blueberries", portion: "½ cup", nutrients: n(42, 0.5, 11, 0.2, 2, 7, 1)),
              Item(name: "Granola", portion: "¼ cup", nutrients: n(120, 3, 18, 4, 2, 6, 40))],
             78, ["high-protein"], "Solid breakfast. Granola adds sugar; nuts would add crunch with less."),
            ("Burrito bowl",
             [Item(name: "Brown rice", portion: "¾ cup", nutrients: n(165, 4, 34, 1.3, 2.5, 0, 5)),
              Item(name: "Black beans", portion: "½ cup", nutrients: n(114, 8, 20, 0.5, 7.5, 0, 200)),
              Item(name: "Carnitas", portion: "100 g", nutrients: n(210, 23, 0, 12, 0, 0, 450)),
              Item(name: "Salsa and guacamole", portion: "", nutrients: n(140, 2, 9, 11, 5, 2, 330))],
             71, ["high-fiber", "balanced"], "Well balanced, with lots of fiber from the beans."),
            ("Glazed donut and latte",
             [Item(name: "Glazed donut", portion: "1", nutrients: n(260, 3, 31, 14, 1, 14, 210)),
              Item(name: "Latte, whole milk", portion: "16 oz", nutrients: n(220, 12, 18, 11, 0, 17, 170))],
             29, ["high-sugar"], "About 31 grams of sugar. Pair coffee with protein to stay full longer."),
            ("Salmon, quinoa and broccoli",
             [Item(name: "Baked salmon", portion: "140 g", nutrients: n(290, 31, 0, 18, 0, 0, 90)),
              Item(name: "Quinoa", portion: "¾ cup", nutrients: n(166, 6, 29, 2.7, 4, 1, 10)),
              Item(name: "Steamed broccoli", portion: "1 cup", nutrients: n(55, 4, 11, 0.6, 5, 2, 60))],
             92, ["high-protein", "omega-3", "high-fiber"], "Excellent. Omega-3s, fiber and protein in one plate."),
        ]
        let pick = menu[abs(mealID.hashValue) % menu.count]
        let totals = pick.1.compactMap(\.nutrients).reduce(Nutrients.zero, +)
        let calories = Int((totals.calories ?? 0).rounded(.toNearestOrEven) / 10) * 10
        return MealResultMessage(
            schema: "dewin.meal.result/1", mealId: mealID, status: "analyzed", processedAt: Date(), error: nil,
            meal: .init(
                name: pick.0, items: pick.1, totals: totals, healthScore: pick.2, tags: pick.3, tips: [pick.4],
                spokenSummary: "\(pick.0), about \(calories) calories."
            )
        )
    }
}
