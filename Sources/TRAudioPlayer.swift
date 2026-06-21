import AVFoundation
import MediaPlayer

/// 音频播放器 - 支持变速播放、波形显示、后台播放
final class TRAudioPlayer: NSObject {
    static let shared = TRAudioPlayer()

    enum PlaybackSpeed: Float, CaseIterable {
        case half = 0.5
        case threeQuarter = 0.75
        case normal = 1.0
        case oneAndQuarter = 1.25
        case oneAndHalf = 1.5
        case double = 2.0

        var label: String {
            switch self {
            case .half: return "0.5x"
            case .threeQuarter: return "0.75x"
            case .normal: return "1x"
            case .oneAndQuarter: return "1.25x"
            case .oneAndHalf: return "1.5x"
            case .double: return "2x"
            }
        }
    }

    enum PlaybackState {
        case idle
        case playing
        case paused
        case stopped
    }

    // MARK: - 属性
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private(set) var state: PlaybackState = .idle
    private(set) var currentURL: URL?
    private(set) var speed: PlaybackSpeed = .normal
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isLooping = false

    var onStateChange: ((PlaybackState) -> Void)?
    var onProgressUpdate: ((TimeInterval, TimeInterval) -> Void)?
    var onPlaybackComplete: (() -> Void)?

    private override init() {
        super.init()
        setupRemoteCommandCenter()
    }

    // MARK: - 播放控制
    func play(url: URL, speed: PlaybackSpeed = .normal) throws {
        try TRAudioSessionManager.shared.activateForPlayback()

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.enableRate = true
        player.rate = speed.rawValue
        player.numberOfLoops = isLooping ? -1 : 0
        player.prepareToPlay()
        player.play()

        self.audioPlayer = player
        self.currentURL = url
        self.speed = speed
        self.duration = player.duration
        self.state = .playing

        startProgressTimer()
        updateNowPlayingInfo()
        onStateChange?(.playing)
    }

    func pause() {
        audioPlayer?.pause()
        state = .paused
        progressTimer?.invalidate()
        onStateChange?(.paused)
        updateNowPlayingInfo()
    }

    func resume() {
        audioPlayer?.play()
        state = .playing
        startProgressTimer()
        onStateChange?(.playing)
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        progressTimer?.invalidate()
        state = .stopped
        currentTime = 0
        currentURL = nil
        onStateChange?(.stopped)
        clearNowPlayingInfo()
        try? TRAudioSessionManager.shared.deactivate()
    }

    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
        updateNowPlayingInfo()
    }

    func skipForward(_ seconds: TimeInterval = 15) {
        let newTime = min((audioPlayer?.currentTime ?? 0) + seconds, duration)
        seek(to: newTime)
    }

    func skipBackward(_ seconds: TimeInterval = 15) {
        let newTime = max((audioPlayer?.currentTime ?? 0) - seconds, 0)
        seek(to: newTime)
    }

    func setSpeed(_ speed: PlaybackSpeed) {
        self.speed = speed
        audioPlayer?.rate = speed.rawValue
    }

    func toggleLoop() {
        isLooping.toggle()
        audioPlayer?.numberOfLoops = isLooping ? -1 : 0
    }

    // MARK: - 波形数据
    func generateWaveformSamples(url: URL, count: Int = 100) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let length = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length)!

        try? file.read(into: buffer)

        guard let channelData = buffer.floatChannelData?[0] else { return [] }
        let sampleCount = Int(buffer.frameLength)
        let samplesPerBin = max(1, sampleCount / count)
        var result: [Float] = []

        for i in 0..<count {
            let start = i * samplesPerBin
            let end = min(start + samplesPerBin, sampleCount)
            var maxAmp: Float = 0
            for j in start..<end {
                let amp = abs(channelData[j])
                if amp > maxAmp { maxAmp = amp }
            }
            result.append(maxAmp)
        }
        return result
    }

    // MARK: - 私有方法
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            self.currentTime = player.currentTime
            self.onProgressUpdate?(self.currentTime, self.duration)
        }
        RunLoop.main.add(progressTimer!, forMode: .common)
    }

    private func updateNowPlayingInfo() {
        guard let url = currentURL else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: url.lastPathComponent,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: speed.rawValue
        ]

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipForward()
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipBackward()
            return .success
        }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            self?.speed = PlaybackSpeed(rawValue: event.playbackRate) ?? .normal
            return .success
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension TRAudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if !isLooping {
            state = .stopped
            progressTimer?.invalidate()
            currentTime = 0
            onStateChange?(.stopped)
            onPlaybackComplete?()
            clearNowPlayingInfo()
        }
    }
}