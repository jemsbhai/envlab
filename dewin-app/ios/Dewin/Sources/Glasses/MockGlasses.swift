#if DEBUG
import MWDATInputs
import MWDATMockDevice
import UIKit

/// Meta's MockDeviceKit: fake Ray-Ban Metas that run the real SDK code paths,
/// so the whole loop can be exercised in the simulator or without the glasses on.
@MainActor
enum MockGlassesKit {
    private static var device: (any MWDATMockDevice.MockGlasses)?

    static var isActive: Bool { device != nil }

    static func start() {
        guard device == nil else { return }
        let kit = MockDeviceKit.shared
        // Registered and permissions granted up front, so no Meta AI round trip.
        kit.enable(config: MockDeviceKitConfig(initiallyRegistered: true, initialPermissionsGranted: true))
        do {
            let glasses = try kit.pairGlasses(model: .rayBanMeta)
            glasses.powerOn()
            glasses.unfold()
            glasses.don()
            // The mock camera needs a video feed to stream; the simulator has no camera.
            if let feed = Bundle.main.url(forResource: "mock-feed", withExtension: "mp4") {
                glasses.services.camera.setCameraFeed(fileURL: feed)
            }
            if let url = testImageURL() {
                glasses.services.camera.setCapturedImage(fileURL: url)
            }
            device = glasses
        } catch {
            NSLog("[Describe] mock pairing failed: \(error)")
        }
    }

    static func stop() {
        if let device { MockDeviceKit.shared.unpairDevice(device) }
        MockDeviceKit.shared.disable()
        device = nil
    }

    /// Simulates the wearer pressing the capture button.
    static func press(_ press: MWDATInputs.CapturePressType) {
        let mock: MWDATMockDevice.CapturePressType = switch press {
        case .shortPress: .shortPress
        case .hold: .hold
        default: .doublePress
        }
        device?.services.input.capture(pressType: mock)
    }

    /// Simulates the wearer speaking: a partial result, then the final one.
    static func say(_ text: String) {
        guard let speech = device?.services.speech else { return }
        let words = text.split(separator: " ")
        if words.count > 1 {
            speech.simulateTranscription(text: words.prefix(2).joined(separator: " "), isFinal: false, confidence: 0.8)
        }
        speech.simulateTranscription(text: text, isFinal: true, confidence: 0.92)
    }

    /// A generated stand-in photo for the mock camera to "capture".
    private static func testImageURL() -> URL? {
        let size = CGSize(width: 640, height: 480)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "Mock glasses photo" as NSString
            text.draw(at: CGPoint(x: 40, y: 220), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 36), .foregroundColor: UIColor.white,
            ])
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "mock-capture.jpg")
        guard let data = image.jpegData(compressionQuality: 0.8), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}
#endif
