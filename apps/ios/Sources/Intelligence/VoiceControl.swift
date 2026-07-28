// Push-to-talk during a scan: "mark this", "what is this", "find my
// keys". Recognition runs ON the phone when the OS supports it (A12+
// does for English) — tap the mic, speak, tap again or just stop
// talking; the final transcript is handed to ScanView's tiny grammar.
// This is deliberately not a wake-word assistant: the mic is hot only
// while the button says it is.
import AVFoundation
import Foundation
import Speech

@MainActor
final class VoiceControl: ObservableObject {
    @Published var listening = false
    @Published var transcript = ""
    @Published var problem: String?
    var onCommand: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(
        locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var delivered = false

    func toggle() {
        listening ? stop(deliver: true) : start()
    }

    private func start() {
        problem = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.problem = "Speech permission is off — enable "
                        + "it in iOS Settings → Theseus."
                    return
                }
                AVAudioSession.sharedInstance()
                    .requestRecordPermission { granted in
                        Task { @MainActor in
                            guard granted else {
                                self.problem = "Microphone permission "
                                    + "is off — enable it in iOS "
                                    + "Settings → Theseus."
                                return
                            }
                            self.begin()
                        }
                    }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now."
            return
        }
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playAndRecord, mode: .measurement,
                               options: [.duckOthers,
                                         .defaultToSpeaker])
        try? audio.setActive(true,
                             options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        delivered = false
        transcript = ""

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024,
                         format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            problem = "Couldn't open the microphone."
            return
        }
        listening = true

        task = recognizer.recognitionTask(with: request) {
            [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text }
                if final || (failed && self.listening) {
                    self.stop(deliver: true)
                }
            }
        }
        // hard cap: a command is seconds, not a speech
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.listening == true { self?.stop(deliver: true) }
        }
    }

    func stop(deliver: Bool) {
        guard listening || request != nil else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        listening = false
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
        if deliver, !delivered, !transcript.isEmpty {
            delivered = true
            onCommand?(transcript)
        }
    }
}
