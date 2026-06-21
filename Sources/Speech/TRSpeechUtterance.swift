import Foundation
import Speech

/// 语音合成与转文字
final class TRSpeechUtterance {
    static let shared = TRSpeechUtterance()

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private(set) var isRecognizing = false
    private(set) var transcribedText = ""

    var onTranscriptionUpdate: ((String) -> Void)?
    var onTranscriptionComplete: ((String) -> Void)?

    private init() {}

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    func startTranscribing(from url: URL) throws {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw NSError(domain: "TRSpeech", code: -1, userInfo: [NSLocalizedDescriptionKey: "语音识别不可用"])
        }

        stopTranscribing()

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            if let result = result {
                self?.transcribedText = result.bestTranscription.formattedString
                self?.onTranscriptionUpdate?(result.bestTranscription.formattedString)
            }
            if error != nil || result?.isFinal == true {
                self?.onTranscriptionComplete?(self?.transcribedText ?? "")
                self?.stopTranscribing()
            }
        }

        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        try audioEngine.start()
        isRecognizing = true
    }

    func stopTranscribing() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecognizing = false
    }

    // MARK: - 文字转语音
    func speak(_ text: String, language: String = "zh-CN") {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.speak(utterance)
    }
}