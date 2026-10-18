import AVFoundation
import AudioToolbox

/// Speaks replies and plays short cues through whatever audio route is active
/// (the glasses' speakers, once they're the Bluetooth output).
@MainActor
final class Speaker {
    enum Cue {
        case capturing, failed

        /// Built-in system sounds, so there are no audio assets to ship yet.
        var soundID: SystemSoundID {
            switch self {
            case .capturing: 1108 // camera shutter
            case .failed: 1073    // short error tone
            }
        }
    }

    private let synth = AVSpeechSynthesizer()

    init() {
        // The session category is owned by AudioRoute (it changes when the wake word listens).
        AudioRoute.configure()
    }

    func say(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(utterance)
    }

    func cue(_ cue: Cue) {
        AudioServicesPlaySystemSound(cue.soundID)
    }
}
