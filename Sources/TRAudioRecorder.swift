import AVFoundation
import UIKit

/// 音频录制器 - 支持通话录音和系统音频录制
final class TRAudioRecorder: NSObject {
    static let shared = TRAudioRecorder()

    // MARK: - 配置
    enum AudioFormat: String, CaseIterable {
        case m4a = "m4a"
        case wav = "wav"
        case mp3 = "mp3"
    }

    struct RecordingConfig {
        var format: AudioFormat = .m4a
        var sampleRate: Double = 44100
        var bitRate: Int = 128000
        var channels: Int = 2
        var quality: AVAudioQuality = .high
    }

    struct RecordingInfo {
        let url: URL
        let startTime: Date
        let config: RecordingConfig
        let isSystemAudio: Bool
        let phoneNumber: String?
        let direction: TRCallMonitor.CallDirection
    }

    // MARK: - 属性
    private var audioRecorder: AVAudioRecorder?
    private var audioEngine: AVAudioEngine?
    private var recordingTimer: Timer?
    private var currentRecordingInfo: RecordingInfo?
    private(set) var isRecording = false
    private(set) var currentDuration: TimeInterval = 0
    private(set) var currentAmplitude: Float = 0

    var config = RecordingConfig()
    var onAmplitudeUpdate: ((Float) -> Void)?
    var onDurationUpdate: ((TimeInterval) -> Void)?
    var onRecordingStart: ((RecordingInfo) -> Void)?
    var onRecordingStop: ((RecordingInfo) -> Void)?

    private let recordingQueue = DispatchQueue(label: "wiki.qaq.trapp.audio.recording")

    private override init() {
        super.init()
    }

    // MARK: - 通话录音
    func startCallRecording(
        phoneNumber: String?,
        direction: TRCallMonitor.CallDirection
    ) throws -> RecordingInfo {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        try TRAudioSessionManager.shared.activateForRecording()

        let url = generateRecordingURL(prefix: "call")
        let settings = buildRecordingSettings()

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.record()

        let info = RecordingInfo(
            url: url,
            startTime: Date(),
            config: config,
            isSystemAudio: false,
            phoneNumber: phoneNumber,
            direction: direction
        )

        self.audioRecorder = recorder
        self.currentRecordingInfo = info
        self.isRecording = true

        startMeteringTimer()
        onRecordingStart?(info)
        TRNotificationCenter.shared.post(name: "recording-did-start")

        print("[TRApp] 通话录音开始: \(url.lastPathComponent)")
        return info
    }

    // MARK: - 系统音频录制
    func startSystemAudioRecording() throws -> RecordingInfo {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        try TRAudioSessionManager.shared.activateForRecording()

        let url = generateRecordingURL(prefix: "system")
        let engine = AVAudioEngine()

        let outputNode = engine.outputNode
        let format = outputNode.outputFormat(forBus: 0)

        let settings = buildRecordingSettings()
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true

        // 安装 tap 在输出节点上捕获系统音频
        outputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            // 计算振幅
            let channelData = buffer.floatChannelData?[0]
            var sum: Float = 0
            let length = Int(buffer.frameLength)
            for i in 0..<length {
                sum += abs(channelData?[i] ?? 0)
            }
            self.currentAmplitude = sum / Float(length)
        }

        try engine.start()
        recorder.record()

        let info = RecordingInfo(
            url: url,
            startTime: Date(),
            config: config,
            isSystemAudio: true,
            phoneNumber: nil,
            direction: .unknown
        )

        self.audioEngine = engine
        self.audioRecorder = recorder
        self.currentRecordingInfo = info
        self.isRecording = true

        startMeteringTimer()
        onRecordingStart?(info)
        TRNotificationCenter.shared.post(name: "recording-did-start")

        print("[TRApp] 系统音频录制开始: \(url.lastPathComponent)")
        return info
    }

    // MARK: - 停止录音
    func stopRecording() {
        guard isRecording else { return }

        audioRecorder?.stop()
        audioEngine?.outputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false

        if let info = currentRecordingInfo {
            onRecordingStop?(info)
            TRNotificationCenter.shared.post(name: "recording-did-stop")
            print("[TRApp] 录音结束: \(info.url.lastPathComponent) 时长: \(currentDuration)秒")
        }

        try? TRAudioSessionManager.shared.deactivate()
        audioRecorder = nil
        currentRecordingInfo = nil
        currentDuration = 0
    }

    // MARK: - 暂停/恢复
    func pauseRecording() {
        audioRecorder?.pause()
        audioEngine?.pause()
        recordingTimer?.invalidate()
        print("[TRApp] 录音暂停")
    }

    func resumeRecording() {
        audioRecorder?.record()
        try? audioEngine?.start()
        startMeteringTimer()
        print("[TRApp] 录音恢复")
    }

    // MARK: - 私有方法
    private func generateRecordingURL(prefix: String) -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateStr = dateFormatter.string(from: Date())
        let fileName = "\(prefix)_\(dateStr).\(config.format.rawValue)"

        let documentsPath = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        let recordingsDir = documentsPath.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        return recordingsDir.appendingPathComponent(fileName)
    }

    private func buildRecordingSettings() -> [String: Any] {
        var settings: [String: Any] = [
            AVSampleRateKey: config.sampleRate,
            AVNumberOfChannelsKey: config.channels,
            AVEncoderAudioQualityKey: config.quality.rawValue
        ]

        switch config.format {
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = config.bitRate
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
        case .mp3:
            settings[AVFormatIDKey] = kAudioFormatMPEGLayer3
            settings[AVEncoderBitRateKey] = config.bitRate
        }

        return settings
    }

    private func startMeteringTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            self.audioRecorder?.updateMeters()
            let power = self.audioRecorder?.averagePower(forChannel: 0) ?? -160
            self.currentAmplitude = self.normalizedPower(power)
            self.currentDuration = self.audioRecorder?.currentTime ?? 0
            self.onAmplitudeUpdate?(self.currentAmplitude)
            self.onDurationUpdate?(self.currentDuration)
        }
        RunLoop.main.add(recordingTimer!, forMode: .common)
    }

    private func normalizedPower(_ decibels: Float) -> Float {
        let minDb: Float = -60.0
        if decibels < minDb { return 0 }
        if decibels >= 0 { return 1 }
        return (decibels - minDb) / -minDb
    }
}

// MARK: - AVAudioRecorderDelegate
extension TRAudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("[TRApp] 录音异常结束")
        }
        // 确保清理
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        audioEngine?.stop()
        audioEngine = nil
        try? TRAudioSessionManager.shared.deactivate()
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("[TRApp] 录音编码错误: \(error?.localizedDescription ?? "未知")")
    }
}

// MARK: - 错误
enum RecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case permissionDenied
    case audioSessionError(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "已经在录音中"
        case .notRecording: return "当前没有在录音"
        case .permissionDenied: return "麦克风权限被拒绝"
        case .audioSessionError(let msg): return "音频会话错误: \(msg)"
        }
    }
}