// Starter for socketio/socket.io-client-swift. Requires the new API gateway.
// Call these methods on the main queue. This example is not an offline queue.
import Foundation
import SocketIO

final class DewinSocket {
    private let manager: SocketManager
    private let socket: SocketIOClient

    init(
        url: URL = URL(string: "https://dewin-api.cbnsndwch.dev")!,
        onExposure: @escaping ([String: Any]) -> Void
    ) {
        manager = SocketManager(
            socketURL: url,
            config: [
                .version(.three), // Socket.IO 3/4 compatibility; Engine.IO 4.
                .path("/socket.io/"),
                .forceWebsockets(true),
                .log(false)
            ]
        )
        socket = manager.defaultSocket
        socket.on("exposure:update") { data, _ in
            guard let exposure = data.first as? [String: Any] else { return }
            onExposure(exposure) // Upsert by exposureId.
        }
    }

    func connect(personalToken: String) {
        socket.connect(withPayload: ["token": personalToken])
    }

    func disconnect() {
        socket.disconnect()
    }

    // Retain eventId, measuredAt, and coordinates for retries of this same fix.
    // A nil callback means an ACK timeout: retry the same payload with backoff.
    func submitLocation(
        eventId: UUID,
        measuredAt: Date,
        latitude: Double,
        longitude: Double,
        accuracyM: Double?,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        var payload: [String: Any] = [
            "schemaVersion": 1,
            "eventId": eventId.uuidString.lowercased(),
            "measuredAt": Self.timestamp(measuredAt),
            "latitude": latitude,
            "longitude": longitude
        ]
        if let accuracyM { payload["accuracyM"] = accuracyM }
        socket.emitWithAck("location:update", payload).timingOut(after: 10) { data in
            completion(data.first as? [String: Any])
        }
    }

    // Call after each reconnect to recover the gap; follow nextCursor for pages.
    func history(
        from: Date,
        to: Date,
        cursor: String? = nil,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        var payload: [String: Any] = [
            "requestId": UUID().uuidString.lowercased(),
            "from": Self.timestamp(from),
            "to": Self.timestamp(to),
            "limit": 100
        ]
        if let cursor { payload["cursor"] = cursor }
        socket.emitWithAck("exposure:history", payload).timingOut(after: 10) { data in
            completion(data.first as? [String: Any])
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
