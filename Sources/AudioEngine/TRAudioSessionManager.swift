import AVFoundation
import UIKit

/// 音频会话管理器 - 管理 AVAudioSession 配置
final class TRAudioSessionManager {
    static let shared = TRAudioSessionManager()

    private let audioSession = AVAudioSession.sharedInstance()
    private(set) var isRecording = false

    private init() {}

    func setup() {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetooth, .mixWithOthers, .defaultToSpeaker]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[TRApp] AudioSession 初始化失败: \(error)")
        }
        setupInterruptionObserver()
        setupRouteChangeObserver()
    }

    func activateForRecording() throws {
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .mixWithOthers])
        try audioSession.setActive(true)
        isRecording = true
    }

    func activateForPlayback() throws {
        try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try audioSession.setActive(true)
    }

    func activateForSilentPlayback() throws {
        // 用于后台保活的静音播放
        try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try audioSession.setActive(true)
    }

    func deactivate() throws {
        isRecording = false
        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            print("[TRApp] 音频中断开始")
            TRNotificationCenter.shared.post(name: "recording-did-stop")
        case .ended:
            if let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if options.contains(.shouldResume) {
                    print("[TRApp] 音频中断结束，恢复录音")
                    try? audioSession.setActive(true)
                    TRNotificationCenter.shared.post(name: "recording-did-start")
                }
            }
        @unknown default:
            break
        }
    }

    private func setupRouteChangeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: audioSession
        )
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonRaw = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
        else { return }

        switch reason {
        case .oldDeviceUnavailable:
            print("[TRApp] 音频设备断开（耳机拔出）")
            if isRecording {
                // 继续录音，不中断
            }
        default:
            break
        }
    }
}