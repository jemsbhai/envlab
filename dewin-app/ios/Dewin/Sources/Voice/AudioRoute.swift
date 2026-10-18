import AVFoundation

/// Owns the audio session. Speech output plays over A2DP to the glasses' speakers.
/// (The wake phrase is recognized on the glasses, so the phone never records.)
enum AudioRoute {
    static func configure() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            NSLog("[Audio] session config failed: %@", error.localizedDescription)
        }
    }
}
