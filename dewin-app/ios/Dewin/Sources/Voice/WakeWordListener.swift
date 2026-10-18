import Foundation
import Observation

/// "Hey Dewin", recognized on the glasses with Meta's on-device speech (MWDATSpeech).
///
/// The glasses send running transcriptions (partial and final); this watches them for
/// the wake phrase, then waits for the rest of the sentence: "Hey Dewin" or "Hey Dewin,
/// log this" takes a photo, "Hey Dewin, how many calories did I eat today?" is a question.
/// The command ends on a final transcription or a short silence. One wake → one command.
@Observable
@MainActor
final class WakeWordListener {
    static let enabledKey = "wakeWordEnabled"
    /// Silence after the last partial that counts as "done talking".
    static let silence: Duration = .milliseconds(1600)
    /// After a bare "Hey Dewin", how long to wait for a follow-up utterance before taking the photo.
    static let followUpGrace: Duration = .milliseconds(1800)

    @ObservationIgnored var onCommand: ((VoiceCommand) -> Void)?
    private(set) var lastHeard = ""

    var enabled: Bool = UserDefaults.standard.bool(forKey: WakeWordListener.enabledKey) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            glasses.listenForSpeech = enabled
        }
    }

    var isListening: Bool { enabled && glasses.speechState == "listening" }
    var statusText: String { enabled ? glasses.speechState : "off" }

    @ObservationIgnored private let glasses: GlassesController
    @ObservationIgnored private var lastWake = Date.distantPast
    /// Text after the wake phrase while a command is being collected; nil when idle.
    @ObservationIgnored private var pending: String?
    @ObservationIgnored private var firedThisUtterance = false
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(glasses: GlassesController) {
        self.glasses = glasses
        glasses.onTranscript = { [weak self] text, isFinal in
            self?.heard(text, isFinal: isFinal)
        }
        glasses.listenForSpeech = enabled
    }

    private func heard(_ text: String, isFinal: Bool) {
        lastHeard = text
        guard enabled else { return }
        defer { if isFinal { firedThisUtterance = false } }

        if pending == nil {
            guard !firedThisUtterance, let rest = Self.remainder(afterWakePhrase: text),
                  Date().timeIntervalSince(lastWake) > 3 else { return }
            lastWake = Date()
            NSLog("[WakeWord] heard %@", text)
            pending = rest
        } else if let rest = Self.remainder(afterWakePhrase: text) {
            pending = rest
        } else if !firedThisUtterance {
            // A new utterance after a bare "Hey Dewin": the whole thing is the command.
            pending = text
        }

        if isFinal, !(pending ?? "").isEmpty {
            finish()
        } else {
            // Bare "Hey Dewin" (final or not) gets longer to see if more is coming.
            schedule(after: (pending ?? "").isEmpty ? Self.followUpGrace : Self.silence)
        }
    }

    private func schedule(after delay: Duration) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        timer?.cancel()
        timer = nil
        guard let text = pending else { return }
        pending = nil
        firedThisUtterance = true
        let command = VoiceCommand.parse(text)
        NSLog("[WakeWord] command %@ (\"%@\")", String(describing: command), text)
        onCommand?(command)
    }

    /// The words after "hey dewin", or nil if the phrase isn't there.
    /// Accepts the spellings a general recognizer produces for "Dewin", including
    /// two-word splits like "do win".
    nonisolated static func remainder(afterWakePhrase text: String) -> String? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        let greetings: Set = ["hey", "hay", "hi", "heyy", "ay", "eh", "a"]
        let names: Set = ["dewin", "devin", "dewan", "duin", "dwin", "dewin's", "deuin", "dewine", "devon", "dewing"]
        let splitNames: Set = ["do win", "due win", "de win", "dew in", "do in", "due in", "dew win", "the win"]
        for (index, word) in words.enumerated() {
            if word == "heydewin" || word == "heydevin" { return words[(index + 1)...].joined(separator: " ") }
            guard greetings.contains(word), index + 1 < words.count else { continue }
            if names.contains(words[index + 1]) { return words[(index + 2)...].joined(separator: " ") }
            if index + 2 < words.count, splitNames.contains("\(words[index + 1]) \(words[index + 2])") {
                return words[(index + 3)...].joined(separator: " ")
            }
        }
        return nil
    }

    nonisolated static func containsWakePhrase(_ text: String) -> Bool {
        remainder(afterWakePhrase: text) != nil
    }
}
