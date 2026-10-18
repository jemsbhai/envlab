import Foundation

// Wire types for the team's envlab Socket.IO API v1 (envlab repo: backend/docs/api-v1.md and
// api-v1.schema.json). Keep the two in sync. Requests follow the strict schema: no unknown keys,
// optional keys left out when nil. Replies are read leniently: unknown keys are ignored and a
// missing optional is unknown, never zero. Foundation only, so it also compiles outside the app.

/// Producer: one GPS fix, the `location:update` event. The server acks once it has stored it.
/// Keep this exact value (event ID, timestamp, coordinates) for every retry of the same fix.
struct EnvlabLocationUpdate: Codable, Sendable, Hashable {
    static let event = "location:update"

    var schemaVersion = 1
    /// Lowercased UUID; the server dedupes on (user, eventId).
    var eventId: String
    /// When the phone took the fix (not when it was sent).
    var measuredAt: Date
    var latitude: Double
    var longitude: Double
    /// Horizontal accuracy in meters. Left out when unknown.
    var accuracyM: Double?

    init(eventId: UUID = UUID(), measuredAt: Date, latitude: Double, longitude: Double, accuracyM: Double? = nil) {
        self.eventId = eventId.uuidString.lowercased()
        self.measuredAt = measuredAt
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyM = accuracyM.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// What the server would reject as `INVALID_PAYLOAD` before it even looks at the timestamp.
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && UUID(uuidString: eventId) != nil
    }
}

/// The `error` object of a failed ACK.
struct EnvlabErrorInfo: Codable, Sendable, Hashable {
    var code: String
    var message: String?
    var field: String?
    var retryable: Bool?

    /// Retry with the same payload: the server says so, or the code is a back-off code.
    var isRetryable: Bool { retryable == true || code == "RATE_LIMITED" || code == "UNAVAILABLE" }

    var summary: String { [code, message].compactMap { $0 }.joined(separator: ": ") }
}

/// Reply to `location:update`. `ok` with `duplicate: true` means this event ID was already stored.
struct EnvlabAck: Codable, Sendable, Hashable {
    var ok: Bool
    var eventId: String?
    var requestId: String?
    var receivedAt: Date?
    var duplicate: Bool?
    var error: EnvlabErrorInfo?
}

/// Consumer: one persisted enrichment of a fix, pushed live as `exposure:update` and returned by
/// `exposure:history`. Upsert by `exposureId`; `locationEventId` is the fix it belongs to.
/// `no_match` is a real result ("no nearby data"), not zero exposure.
struct Exposure: Codable, Identifiable, Hashable, Sendable {
    struct Position: Codable, Hashable, Sendable {
        var latitude: Double
        var longitude: Double
        var accuracyM: Double?
    }

    /// One nearby sensor device and its readings, as of the fix's time.
    struct Sensor: Codable, Hashable, Sendable {
        var deviceId: String
        /// e.g. "demo-school".
        var locationId: String?
        /// "public" or "private" (your own home sensor).
        var visibility: String?
        var distanceM: Double?
        var position: Position?
        /// The sensor's own timestamp; nil when its clock was unsynchronized.
        var measuredAt: Date?
        var receivedAt: Date?
        /// The time used for matching: `measuredAt` when valid, else `receivedAt`.
        var observedAt: Date?
        /// "sensor" or "simulated". Always label simulated data.
        var source: String?
        var measurements: [Measurement]

        var isSimulated: Bool { source == "simulated" }
        var isPrivate: Bool { visibility == "private" }
    }

    struct Measurement: Codable, Hashable, Sendable {
        var sensorId: String?
        /// "air" or "water".
        var medium: String
        /// Extensible: "temperature", "humidity", "pm2_5", "co2", "ph", "turbidity", "conductivity", …
        var metric: String
        var value: Double
        var unit: String?
        /// "ok", "uncalibrated" (show the label) or "invalid" (don't show).
        var quality: String?
        var rollingMean: Double?
        var sampleCount: Int?
        var windowSeconds: Double?
    }

    var schemaVersion: Int?
    var exposureId: String
    var locationEventId: String
    /// When the phone took the fix.
    var measuredAt: Date
    var receivedAt: Date?
    var processedAt: Date?
    /// Where the phone was.
    var position: Position
    /// "matched", "no_match", or a future value.
    var status: String
    var matchRadiusM: Double?
    var maxSensorAgeSeconds: Double?
    /// Nearest first. Empty for `no_match`.
    var sensors: [Sensor]

    var id: String { exposureId }
    var isMatched: Bool { status == "matched" }
    var isSimulated: Bool { sensors.contains(where: \.isSimulated) }
}

extension Exposure {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        exposureId = try container.decode(String.self, forKey: .exposureId)
        locationEventId = try container.decode(String.self, forKey: .locationEventId)
        measuredAt = try container.decode(Date.self, forKey: .measuredAt)
        receivedAt = try container.decodeIfPresent(Date.self, forKey: .receivedAt)
        processedAt = try container.decodeIfPresent(Date.self, forKey: .processedAt)
        position = try container.decode(Position.self, forKey: .position)
        status = try container.decode(String.self, forKey: .status)
        matchRadiusM = try container.decodeIfPresent(Double.self, forKey: .matchRadiusM)
        maxSensorAgeSeconds = try container.decodeIfPresent(Double.self, forKey: .maxSensorAgeSeconds)
        sensors = container.decodeLossyArray(Sensor.self, forKey: .sensors) ?? []
    }
}

extension Exposure.Sensor {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        locationId = try container.decodeIfPresent(String.self, forKey: .locationId)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        distanceM = try container.decodeIfPresent(Double.self, forKey: .distanceM)
        position = try container.decodeIfPresent(Exposure.Position.self, forKey: .position)
        measuredAt = try container.decodeIfPresent(Date.self, forKey: .measuredAt)
        receivedAt = try container.decodeIfPresent(Date.self, forKey: .receivedAt)
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        measurements = container.decodeLossyArray(Exposure.Measurement.self, forKey: .measurements) ?? []
    }
}

/// Consumer API: the `exposure:history` event. Range is `[from, to)` on the fix's `measuredAt`,
/// at most 31 days. Follow `nextCursor` with the same bounds and limit.
struct EnvlabHistoryRequest: Codable, Sendable, Hashable {
    static let event = "exposure:history"

    var requestId: String
    var from: Date
    var to: Date
    /// 1…200.
    var limit: Int
    /// Left out on the first page. Opaque: never parse or build one.
    var cursor: String?
}

/// Reply to `exposure:history`. Items are oldest first, ordered by (measuredAt, exposureId).
struct EnvlabHistoryPage: Codable, Sendable {
    var ok: Bool
    var requestId: String?
    var items: [Exposure]?
    var nextCursor: String?
    var error: EnvlabErrorInfo?
}

extension EnvlabHistoryPage {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        // One unreadable record shouldn't hide the rest of the page.
        items = container.decodeLossyArray(Exposure.self, forKey: .items)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        error = try container.decodeIfPresent(EnvlabErrorInfo.self, forKey: .error)
    }
}

enum EnvlabCodingError: LocalizedError {
    case notJSON
    case notAnObject

    var errorDescription: String? {
        switch self {
        case .notJSON: "The payload isn't JSON."
        case .notAnObject: "The payload isn't a JSON object."
        }
    }
}

/// JSON for the envlab API. Dates are RFC 3339: read with or without fractional seconds and with any
/// offset; written in UTC with milliseconds ("2026-10-18T19:00:00.120Z"). Writing rounds to whole
/// milliseconds, so a date that went through a file and back encodes to the very same string
/// (a retried fix must be byte-identical or the server answers `EVENT_ID_CONFLICT`).
enum EnvlabCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an RFC 3339 date: \(string)")
            }
            return date
        }
        return decoder
    }()

    /// "2026-10-18T19:00:00.120Z".
    static func string(from date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        let seconds = (milliseconds / 1_000).rounded(.down)
        let fraction = Int(milliseconds - seconds * 1_000)
        let whole = plain.string(from: Date(timeIntervalSince1970: seconds)) // "…:00Z"
        return String(whole.dropLast()) + String(format: ".%03ldZ", fraction)
    }

    /// Any RFC 3339 timestamp: "…T19:00:00Z", "…T19:00:00.123456+00:00", "…t15:00:00-04:00".
    static func date(from string: String) -> Date? {
        let characters = Array(string.uppercased())
        guard characters.count >= 20 else { return nil }
        var index = 19 // after "YYYY-MM-DDTHH:MM:SS"
        var fraction = 0.0
        if characters[index] == "." {
            var end = index + 1
            while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
            guard end > index + 1, let value = Double("0." + String(characters[(index + 1)..<end])) else { return nil }
            fraction = value
            index = end
        }
        guard index < characters.count else { return nil }
        let text = String(characters[0..<19]) + String(characters[index...])
        return plain.date(from: text)?.addingTimeInterval(fraction)
    }

    /// A Codable value as the `[String: Any]` Socket.IO emits as a JSON object.
    static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EnvlabCodingError.notAnObject
        }
        return object
    }

    /// A Socket.IO payload (a JSON object or array, JSON text, or JSON data) as a Decodable value.
    static func decode<T: Decodable>(_ type: T.Type, from payload: Any?) throws -> T {
        let data: Data
        switch payload {
        case let bytes as Data: data = bytes
        case let string as String: data = Data(string.utf8)
        case let object? where JSONSerialization.isValidJSONObject(object):
            data = try JSONSerialization.data(withJSONObject: object)
        default: throw EnvlabCodingError.notJSON
        }
        return try decoder.decode(type, from: data)
    }

    /// RFC 3339 without fractional seconds, UTC.
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct EnvlabSkipped: Decodable {
    init(from decoder: Decoder) throws {}
}

private extension KeyedDecodingContainer {
    /// The elements that decode; the rest are skipped. Nil when the key is missing, null, or not an array.
    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
        guard var list = try? nestedUnkeyedContainer(forKey: key) else { return nil }
        var result: [T] = []
        while !list.isAtEnd {
            if let value = try? list.decode(T.self) {
                result.append(value)
            } else if (try? list.decode(EnvlabSkipped.self)) == nil {
                break
            }
        }
        return result
    }
}
