import Foundation
import CoreFoundation

/// Darwin 通知系统 - 进程间通信
final class TRNotificationCenter {
    static let shared = TRNotificationCenter()

    private var observers: [String: [(String, [String: Any]?) -> Void]] = [:]

    private init() {}

    func setup() {
        // 注册关键通知监听
        observe(name: "recording-did-start") { [weak self] name, _ in
            self?.handleRecordingDidStart()
        }
        observe(name: "recording-did-stop") { [weak self] name, _ in
            self?.handleRecordingDidStop()
        }
        observe(name: "prefs-reload") { [weak self] name, _ in
            self?.handlePrefsReload()
        }
        print("[TRApp] Darwin 通知系统已初始化")
    }

    // MARK: - 发送通知
    func post(name: String, userInfo: [String: Any]? = nil) {
        let cfName = CFNotificationName(name as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            cfName,
            nil,
            userInfo as CFDictionary?,
            true
        )
        // 同时通知本地观察者
        DispatchQueue.main.async { [weak self] in
            self?.observers[name]?.forEach { $0(name, userInfo) }
        }
    }

    // MARK: - 注册监听
    func observe(name: String, handler: @escaping (String, [String: Any]?) -> Void) {
        if observers[name] == nil {
            observers[name] = []
            // 注册 Darwin 通知
            let cfName = CFNotificationName(name as CFString)
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, name, _, userInfo in
                    guard let observer = observer,
                          let name = name else { return }
                    let selfPtr = Unmanaged<TRNotificationCenter>.fromOpaque(observer).takeUnretainedValue()
                    let noteName = (name.rawValue as String)
                    let info = userInfo as? [String: Any]
                    selfPtr.observers[noteName]?.forEach { $0(noteName, info) }
                },
                cfName.rawValue,
                nil,
                .deliverImmediately
            )
        }
        observers[name]?.append(handler)
    }

    // MARK: - 内部处理
    private func handleRecordingDidStart() {
        print("[TRApp] 录音开始通知")
        if !TRBackgroundTaskManager.shared.isActive {
            TRBackgroundTaskManager.shared.startAllKeepAliveStrategies()
        }
    }

    private func handleRecordingDidStop() {
        print("[TRApp] 录音停止通知")
    }

    private func handlePrefsReload() {
        print("[TRApp] 偏好设置重载")
        // 重新加载 UserDefaults 中的设置
        UserDefaults.standard.synchronize()
    }
}